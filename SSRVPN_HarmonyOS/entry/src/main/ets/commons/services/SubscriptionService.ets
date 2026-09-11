/**
 * 订阅服务：增删改查 + 刷新 + 撤销；手工节点独立存储（ManualNodeStore）
 * 移植自 upstream: SSRVPN_Android/lib/services/subscription_service.dart
 *                packages/ssrvpn_shared/lib/services/subscription_service_*.dart
 *                subscription_processing.dart / subscription_undo_record.dart
 *
 * 敏感凭据存储策略（对齐 SettingsService.apiSecret 的 AssetStore 先例）：
 * - 节点 password/uuid/protocolParam/obfsParam、订阅 headerValue 只允许写入系统加密
 *   AssetStore（@ohos.security.asset / @kit.AssetStoreKit），禁止降级为明文 preferences。
 * - 其余节点元数据（server/port/method/network/TLS 参数等）仍存 preferences，
 *   alias 采用稳定键 "ssrvpn_node|<nodeId>|<field>" / "ssrvpn_sub|<subId>|headerValue"。
 * - Asset 缺失（首次升级、清除数据、写入失败回滚）时回退读取一次性绑定字段：
 *   节点用 node.rawUri（上游同样只写 Asset，绝不写 preferences），订阅用内存态，
 *   两者都不落盘明文。
 * - 一次性迁移：把历史明文 preferences 中的凭据写入 Asset 并回读校验，成功后才删除明文；
 *   任一步失败保留明文并记录，绝不丢数据。迁移幂等（重跑只重写加密层，不清明文）。
 */
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { Subscription, SubscriptionRefreshResult, SubscriptionRefreshStatus } from '../models/Subscription';
import { ProxyNode, ProxyNodeType, SsrCodec } from '../models/ProxyNode';
import { SubscriptionParser } from './SubscriptionParser';
import { SubscriptionFetchPolicy } from './SubscriptionFetchPolicy';
import { YamlMerger, MergedProxy } from './YamlMerger';
import {
  CredentialStore, CredentialMigrationReport, NodeCredentialValues, SubscriptionCredentialSource,
  CRED_PREF_NAME, MIGRATION_FLAG_KEY, NODE_CRED_FIELDS, nodeCredentialId, setCredentialLogger
} from './CredentialStore';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'SubscriptionService';

const PREF_NAME = 'ssrvpn_subscriptions';
const KEY_SUBS = 'subscriptions_json';
const KEY_NODES = 'nodes_json';
const KEY_HIDDEN = 'hidden_nodes_json';

/** 一次性回退源（rawUri）在偏好中的键；节点凭据加密写入成功后即删除 */
function nodeUriKey(nodeId: string): string {
  return `rawuri|${nodeId}`;
}

export class SubscriptionService {
  private store: preferences.Preferences | null = null;
  /** 敏感凭据专用偏好（只放一次性绑定，不放凭据本体） */
  private credStore: preferences.Preferences | null = null;
  /** 明文清扫是否已结束（结束后节点凭据完全由 AssetStore 承担） */
  private sealedPlaintextKeys: boolean = false;
  subscriptions: Subscription[] = [];
  nodes: ProxyNode[] = [];
  /** 用户手动删除的节点指纹清单: 订阅刷新时过滤, 防止已删节点"复活" */
  private hiddenNodes: string[] = [];
  /** 撤销记录（对应 subscription_undo_record.dart）：最近一次删除的订阅与节点 */
  private undoSnapshot: SubscriptionUndoSnapshot | null = null;
  /** 敏感凭据已由本实例加载/写入加密层（幂等闸门） */
  private credentialsReady: boolean = false;

  async init(context: Context): Promise<void> {
    this.store = await preferences.getPreferences(context, PREF_NAME);
    this.subscriptions = [];
    this.nodes = [];
    this.hiddenNodes = [];

    // 敏感凭据专用 preferences（仅存放一次性绑定字段，凭据本体在 AssetStore）
    if (this.credStore === null) {
      this.credStore = await preferences.getPreferences(context, CRED_PREF_NAME);
    }
    setCredentialLogger((msg: string) => AppLogger.info(TAG, msg));

    try {
      const subsRaw = await this.store.get(KEY_SUBS, '[]') as string;
      this.subscriptions = SubscriptionService.mapSubs(JSON.parse(subsRaw) as Object);
    } catch (e) {
      AppLogger.warn(TAG, 'invalid subscriptions preferences ignored');
    }

    try {
      const nodesRaw = await this.store.get(KEY_NODES, '[]') as string;
      this.nodes = SubscriptionService.mapNodes(JSON.parse(nodesRaw) as Object);
    } catch (e) {
      AppLogger.warn(TAG, 'invalid nodes preferences ignored');
    }

    try {
      const hiddenRaw = await this.store.get(KEY_HIDDEN, '[]') as string;
      const arr = JSON.parse(hiddenRaw) as string[];
      if (Array.isArray(arr)) {
        this.hiddenNodes = arr.filter((x): boolean => typeof x === 'string');
      }
    } catch (e) {
      AppLogger.warn(TAG, 'invalid hidden nodes preferences ignored');
    }

    // 1) 一次性凭据迁移（必须在任何 persist 之前，避免明文被再次写回）
    await this.runCredentialMigrationOnce();
    // 2) 从加密层回填订阅凭据（headerValue 从不落 preferences）
    await this.hydrateSubscriptionCredentials();
    // 3) 节点凭据回填（Asset 缺失时用一次性 rawUri 解析兜底）
    await this.initNodes(this.nodes);

    // 4) 明文清扫：加密层验证通过的记录删除 preferences 明文字段
    // 历史数据可能存在重名节点(内核会拒绝启动), 加载时即去重并落库
    const renamed = this.ensureUniqueNames();

    AppLogger.info(TAG, `loaded ${this.subscriptions.length} subscriptions, ${this.nodes.length} nodes`);
    if (renamed) {
      await this.persist();
    }
  }

  /**
   * 一次性迁移：把历史 preferences 明文凭据写入 AssetStore（写后回读校验），
   * 全部成功后才清除明文键。任一失败保留明文并记录，绝不丢数据。
   * 幂等：非首启时不再改写凭据本体（只补建缺失项），也不重复清明文。
   */
  private async runCredentialMigrationOnce(): Promise<void> {
    await CredentialStore.loadMigrationFlag();
    const firstRun = CredentialStore.isFirstRun();
    let plainKeys: string[] = [];
    if (this.credStore !== null) {
      const raw = await this.credStore.get('sealed_node_keys_json', '[]') as string;
      plainKeys = SubscriptionService.readJsonStringArray(raw);
    }

    const sources: SubscriptionCredentialSource[] = [];
    for (const s of this.subscriptions) {
      const src = new SubscriptionCredentialSource();
      src.id = s.id;
      src.headerValue = s.headerValue;
      if (s.headerValue.length > 0) {
        sources.push(src);
      }
    }

    let report: CredentialMigrationReport;
    try {
      report = await CredentialStore.canonicalize(this.nodes, sources, !firstRun);
    } catch (e) {
      AppLogger.warn(TAG, `credential canonicalize aborted: ${e instanceof Error ? e.message : String(e)}`);
      return;
    }

    // 节点若仍受明文约束（Asset 写入/校验失败），其 rawUri 必须继续保留作回退源
    const keepIds = new Set<string>();
    for (const n of this.nodes) {
      let bound = false;
      let boundField = '';
      for (const f of NODE_CRED_FIELDS) {
        if (f === 'password' && n.password.length > 0) {
          bound = true;
          boundField = f;
        } else if (f === 'uuid' && n.uuid.length > 0) {
          bound = true;
          boundField = f;
        } else if (f === 'protocolParam' && n.protocolParam.length > 0) {
          bound = true;
          boundField = f;
        } else if (f === 'obfsParam' && n.obfsParam.length > 0) {
          bound = true;
          boundField = f;
        }
      }
      if (bound && !report.fieldFailed(nodeCredentialId(n), boundField)) {
        keepIds.add(nodeCredentialId(n));
      }
    }

    this.credentialsReady = true;

    if (report.failed > 0) {
      // Asset 不可用或个别凭据校验失败：绝不清明文，也不做任何持久化（保留现状）
      CredentialStore.logAssetUnavailable('migration');
      AppLogger.warn(TAG,
        `credential migration incomplete: ${report.failed} field(s) failed; plaintext preserved`);
      return;
    }
    if (!firstRun) {
      // 幂等：非首启不重复清除
      AppLogger.info(TAG, `credential migration idempotent: ${report.alreadyStored} verified, ${report.addedNew} added`);
      return;
    }

    // 首启且全部校验通过 → 清 preferences 明文凭据（节点 JSON 字段 + 订阅 headerValue 已由 toJson 恒空）
    await this.sealPlaintext(plainKeys, keepIds);
    await this.markMigrationDone();
    AppLogger.info(TAG,
      `credential migration done: ${report.migratedNodes} node(s) / ${report.migratedSubscriptions} sub credential(s) moved to asset store`);
  }

  /** 残留一键扫描（专项验证用）：返回 preferences 中仍可枚举到的明文凭据键 */
  async scanPlaintextResidue(): Promise<string[]> {
    const out: string[] = [];
    if (this.store === null) {
      return out;
    }
    const nodesRaw = await this.store.get(KEY_NODES, '[]') as string;
    const subsRaw = await this.store.get(KEY_SUBS, '[]') as string;
    for (const field of CredentialStore.plaintextFieldKeys()) {
      const needle = `"${field}":"`;
      if (nodesRaw.includes(needle)) {
        const probe = `"${field}":""`;
        // 空串是规范化目标，只有非空值才算残留
        const hit = nodesRaw.indexOf(needle);
        if (hit >= 0 && !nodesRaw.startsWith(probe, hit)) {
          out.push(`nodes_json.${field}`);
        }
      }
      if (subsRaw.includes(needle)) {
        out.push(`subscriptions_json.${field}`);
      }
    }
    return out;
  }

  /**
   * 清除已迁移成功的明文凭据。
   * 节点：清 preferences JSON 字段并 flush；确认写入成功后才释放 rawUri 回退源。
   * 订阅：headerValue 已不参与序列化（Subscription.toJson 恒空），无需额外处理。
   */
  private async sealPlaintext(plainKeys: string[], keepIds: Set<string>): Promise<void> {
    if (this.store !== null) {
      try {
        for (const n of this.nodes) {
          if (keepIds.has(nodeCredentialId(n))) {
            continue;
          }
          n.password = '';
          n.uuid = '';
          n.protocolParam = '';
          n.obfsParam = '';
          n.rawYaml = '';
          n.rawUri = '';
        }
        await this.store.put(KEY_NODES, JSON.stringify(SubscriptionService.nodesToJson(this.nodes)));
        await this.store.flush();
      } catch (e) {
        AppLogger.warn(TAG,
          `plaintext seal failed (plaintext kept in memory only, no credential loss): ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    if (this.nodes.length > 0 || plainKeys.length > 0) {
      this.sealedPlaintextKeys = true;
    }
  }

  private async markMigrationDone(): Promise<void> {
    if (this.credStore === null) {
      return;
    }
    try {
      await this.credStore.put(MIGRATION_FLAG_KEY, '1');
      await this.credStore.flush();
    } catch (e) {
      AppLogger.warn(TAG, `migration flag write failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private static readJsonStringArray(raw: string): string[] {
    try {
      const arr = JSON.parse(raw) as string[];
      return Array.isArray(arr) ? arr : [];
    } catch (e) {
      return [];
    }
  }

  /**
   * 回填订阅凭据：Asset 缺失时保持内存态原值（本进程内新输入），
   * 不回退任何持久化明文来源。
   */
  private async hydrateSubscriptionCredentials(): Promise<void> {
    for (const s of this.subscriptions) {
      const value = await CredentialStore.subscriptionCredential(s.id, s.headerValue);
      s.headerValue = value;
    }
  }

  /**
   * 节点凭据回填：Asset 优先。
   * 缺失时回退一次性绑定的 rawUri（内存解析，绝不落盘），在加密层写入成功后即解除绑定。
   */
  async initNodes(nodes: ProxyNode[]): Promise<void> {
    if (this.credStore === null) {
      return;
    }
    const raw = await this.credStore.get('sealed_node_keys_json', '[]') as string;
    const sealed = new Set<string>();
    for (const k of SubscriptionService.readJsonStringArray(raw)) {
      sealed.add(k);
    }
    for (const n of nodes) {
      let uri = '';
      if (!sealed.has(nodeCredentialId(n))) {
        uri = await this.credStore.get(nodeUriKey(nodeCredentialId(n)), '') as string;
      }
      const fallback = SubscriptionService.parseFallbackCredentials(n, uri);
      const values = await CredentialStore.nodeCredentials(nodeCredentialId(n), fallback);
      n.password = values.password;
      n.uuid = values.uuid;
      n.protocolParam = values.protocolParam;
      n.obfsParam = values.obfsParam;
      if (uri.length > 0) {
        await this.markNodeSealed(nodeCredentialId(n), n, sealed);
      }
    }
  }

  /** 一次性回退源用完后移除 preferences 中的副本（Asset 已持有加密凭据） */
  private async markNodeSealed(nodeId: string, node: ProxyNode, sealed: Set<string>): Promise<void> {
    if (this.credStore === null) {
      return;
    }
    try {
      await this.credStore.delete(nodeUriKey(nodeId));
      sealed.add(nodeId);
      await this.credStore.put('sealed_node_keys_json', JSON.stringify(Array.from(sealed)));
      await this.credStore.flush();
    } catch (e) {
      AppLogger.warn(TAG, `sealed node record update failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /**
   * 一次性回退源解析：优先 rawUri（历史版本持久化的原始节点链接），
   * 其次从节点自身字段（老版本明文，尚未被清扫时）还原。结果只驻留内存。
   */
  private static parseFallbackCredentials(n: ProxyNode, uri: string): NodeCredentialValues {
    const out = new NodeCredentialValues();
    out.password = n.password;
    out.uuid = n.uuid;
    out.protocolParam = n.protocolParam;
    out.obfsParam = n.obfsParam;
    if (uri.length === 0) {
      return out;
    }
    let parsed: ProxyNode | null = null;
    try {
      parsed = ProxyNode.fromUri(uri, n.subscriptionId, n.id);
    } catch (e) {
      AppLogger.warn(TAG, 'rawUri fallback parse failed');
      return out;
    }
    if (parsed === null) {
      return out;
    }
    if (parsed.password.length > 0) {
      out.password = parsed.password;
    }
    if (parsed.uuid.length > 0) {
      out.uuid = parsed.uuid;
    }
    if (parsed.protocolParam.length > 0) {
      out.protocolParam = parsed.protocolParam;
    }
    if (parsed.obfsParam.length > 0) {
      out.obfsParam = parsed.obfsParam;
    }
    return out;
  }

  /** 节点稳定指纹（跨刷新不变, 用于删除记忆）。name 用去重前的原始名, 与刷新解析结果一致 */
  static nodeKey(n: ProxyNode): string {
    return `${n.subscriptionId}|${n.server}|${n.port}|${SubscriptionService.baseName(n.name)}`;
  }

  /** 去掉 " #2" 类去重后缀, 还原节点原始名 */
  private static baseName(name: string): string {
    return name.replace(/\s#\d+$/, '');
  }

  /**
   * 全局节点名去重: mihomo 对 proxies 段重名直接拒绝启动
   * ("parse config: proxy X is the duplicate name") —— 一个重名会让
   * 整个内核起不来, 所有节点都连不上。按列表顺序给重名节点追加
   * " #2/#3..." 后缀; UI/PROXY 组/内核配置/API 选节点共用此名, 天然一致。
   * 返回是否发生了改名。
   */
  ensureUniqueNames(): boolean {
    const used = new Set<string>();
    let changed = false;
    for (const n of this.nodes) {
      const original = n.name;
      if (used.has(original)) {
        let k = 2;
        while (used.has(`${original} #${k}`)) {
          k = k + 1;
        }
        n.name = `${original} #${k}`;
        changed = true;
      }
      used.add(n.name);
    }
    return changed;
  }

  /**
   * 删除单个节点（订阅页长按）: 从列表移除并记入隐藏清单,
   * 后续订阅刷新自动过滤; 手动直连节点同样支持（重新导入链接可再次添加）。
   */
  async removeNode(nodeId: string): Promise<boolean> {
    const n = this.findNode(nodeId);
    if (n === null) {
      return false;
    }
    const key = SubscriptionService.nodeKey(n);
    if (!this.hiddenNodes.includes(key)) {
      this.hiddenNodes.push(key);
    }
    this.nodes = this.nodes.filter((x) => x.id !== nodeId);
    const sub = this.subscriptions.find((s) => s.id === n.subscriptionId);
    if (sub !== undefined) {
      sub.nodeCount = this.nodesOf(sub.id).length;
    }
    await this.persist();
    AppLogger.info(TAG, `node removed: ${n.name} (hidden total ${this.hiddenNodes.length})`);
    return true;
  }

  private static validString(value: Object, maxLength: number, allowEmpty: boolean = true): boolean {
    return typeof value === 'string' && value.length <= maxLength && (allowEmpty || value.length > 0);
  }

  private static validInteger(value: Object, min: number, max: number): boolean {
    return typeof value === 'number' && Number.isInteger(value) && value >= min && value <= max;
  }

  private static validRefreshStatus(value: string): boolean {
    return value === '' || value === SubscriptionRefreshStatus.OK
      || value === SubscriptionRefreshStatus.NOT_MODIFIED
      || value === SubscriptionRefreshStatus.NETWORK_ERROR
      || value === SubscriptionRefreshStatus.PARSE_ERROR
      || value === SubscriptionRefreshStatus.HTTP_ERROR;
  }

  private static mapSubs(json: Object): Subscription[] {
    const out: Subscription[] = [];
    if (!Array.isArray(json)) {
      AppLogger.warn(TAG, 'subscriptions preferences root is not an array');
      return out;
    }
    let skipped = 0;
    for (const item of json as Object[]) {
      if (item === null || typeof item !== 'object') {
        skipped++;
        continue;
      }
      const j = item as SubscriptionJson;
      if (!SubscriptionService.validString(j.id, 256, false)
        || !SubscriptionService.validString(j.name, 4096)
        || !SubscriptionService.validString(j.url, 8192, false)
        || !SubscriptionService.validString(j.headerName, 256)
        || !SubscriptionService.validString(j.headerValue, 16 * 1024)
        || !SubscriptionService.validString(j.lastRefreshResult, 64)
        || !SubscriptionService.validRefreshStatus(j.lastRefreshResult)
        || !SubscriptionService.validInteger(j.lastFetchedAt, 0, Number.MAX_SAFE_INTEGER)
        || !SubscriptionService.validInteger(j.nodeCount, 0, 100000)
        || typeof j.enabled !== 'boolean'
        || !SubscriptionService.validInteger(j.sortOrder, 0, 100000)) {
        skipped++;
        continue;
      }
      out.push(Subscription.fromPersistJson(j));
    }
    if (skipped > 0) {
      AppLogger.warn(TAG, `ignored ${skipped} invalid subscription records`);
    }
    return out;
  }

  /** 合并结果 → 节点模型（仅映射白名单结构化字段，proxyType 保留真实类型） */
  private static mergedToNodes(merged: MergedProxy[], subscriptionId: string): ProxyNode[] {
    const out: ProxyNode[] = [];
    let counter = 0;
    for (const m of merged) {
      const n = new ProxyNode();
      n.id = `${subscriptionId}-m${counter++}`;
      n.subscriptionId = subscriptionId;
      n.name = m.name;
      n.server = m.server;
      n.port = m.port;
      n.password = m.password;
      n.method = m.cipher;
      n.protocol = m.protocol;
      n.protocolParam = m.protocolParam;
      n.obfs = m.obfs;
      n.obfsParam = m.obfsParam;
      n.proxyType = m.type;
      n.uuid = m.uuid;
      n.alterId = m.alterId;
      n.udp = m.udp;
      n.network = m.network;
      n.tls = m.tls;
      n.servername = m.servername;
      n.skipCertVerify = m.skipCertVerify;
      n.flow = m.flow;
      n.clientFingerprint = m.clientFingerprint;
      n.realityPublicKey = m.realityPublicKey;
      n.realityShortId = m.realityShortId;
      n.wsPath = m.wsPath;
      n.wsHost = m.wsHost;
      n.grpcServiceName = m.grpcServiceName;
      n.hyUp = m.hyUp;
      n.hyDown = m.hyDown;
      n.alpnList = m.alpnList;
      n.extraOpts = m.extraOpts;
      n.rawYaml = '';
      if (m.type === 'ssr') {
        n.type = ProxyNodeType.SSR;
      } else if (m.type === 'ss') {
        n.type = ProxyNodeType.SS;
      } else {
        n.type = ProxyNodeType.UNKNOWN;
      }
      if (n.server.length > 0 && n.port > 0) {
        out.push(n);
      }
    }
    return out;
  }

  public static mapNodes(json: Object): ProxyNode[] {
    const out: ProxyNode[] = [];
    if (!Array.isArray(json)) {
      AppLogger.warn(TAG, 'nodes preferences root is not an array');
      return out;
    }
    let skipped = 0;
    for (const item of json as Object[]) {
      if (item === null || typeof item !== 'object') {
        skipped++;
        continue;
      }
      const j = item as ProxyNodeJson;
      const validType = j.type === 'ss' || j.type === 'ssr' || j.type === 'other';
      if (!SubscriptionService.validString(j.id, 256, false)
        || !SubscriptionService.validString(j.subscriptionId, 256, false)
        || !SubscriptionService.validString(j.name, 4096)
        || !SubscriptionService.validString(j.server, 4096, false)
        || !SubscriptionService.validInteger(j.port, 1, 65535)
        || !SubscriptionService.validString(j.password, 64 * 1024)
        || !SubscriptionService.validString(j.method, 256)
        || !SubscriptionService.validString(j.protocol, 256)
        || !SubscriptionService.validString(j.protocolParam, 64 * 1024)
        || !SubscriptionService.validString(j.obfs, 256)
        || !SubscriptionService.validString(j.obfsParam, 64 * 1024)
        || !SubscriptionService.validString(j.type, 32, false)
        || !validType
        || !SubscriptionService.validString(j.proxyType, 64)
        || !SubscriptionService.validString(j.uuid, 4096)
        || !SubscriptionService.validInteger(j.alterId, 0, 2147483647)
        || typeof j.udp !== 'boolean'
        || !SubscriptionService.validString(j.network, 256)
        || typeof j.tls !== 'boolean'
        || !SubscriptionService.validString(j.servername, 4096)
        || typeof j.skipCertVerify !== 'boolean'
        || !SubscriptionService.validString(j.flow, 4096)
        || !SubscriptionService.validString(j.clientFingerprint, 256)
        || !SubscriptionService.validString(j.realityPublicKey, 4096)
        || !SubscriptionService.validString(j.realityShortId, 4096)
        || !SubscriptionService.validString(j.wsPath, 64 * 1024)
        || !SubscriptionService.validString(j.wsHost, 4096)
        || !SubscriptionService.validString(j.grpcServiceName, 64 * 1024)
        || (j.hyUp !== undefined && !SubscriptionService.validString(j.hyUp, 256))
        || (j.hyDown !== undefined && !SubscriptionService.validString(j.hyDown, 256))
        || (j.alpnList !== undefined && !SubscriptionService.validString(j.alpnList, 256))
        || (j.extraOpts !== undefined && !SubscriptionService.validString(j.extraOpts, 64 * 1024))
        || !SubscriptionService.validString(j.rawYaml, 128 * 1024)
        || !SubscriptionService.validString(j.rawUri, 128 * 1024)) {
        skipped++;
        continue;
      }
      const n = new ProxyNode();
      n.id = j.id;
      n.subscriptionId = j.subscriptionId;
      n.name = j.name;
      n.server = j.server;
      n.port = j.port;
      n.password = j.password;
      n.method = j.method;
      n.protocol = j.protocol;
      n.protocolParam = j.protocolParam;
      n.obfs = j.obfs;
      n.obfsParam = j.obfsParam;
      n.type = j.type === 'ss' ? ProxyNodeType.SS : (j.type === 'ssr' ? ProxyNodeType.SSR : ProxyNodeType.UNKNOWN);
      n.proxyType = j.proxyType.length > 0 ? j.proxyType : j.type;
      n.uuid = j.uuid;
      n.alterId = j.alterId;
      n.udp = j.udp;
      n.network = j.network;
      n.tls = j.tls;
      n.servername = j.servername;
      n.skipCertVerify = j.skipCertVerify;
      n.flow = j.flow;
      n.clientFingerprint = j.clientFingerprint;
      n.realityPublicKey = j.realityPublicKey;
      n.realityShortId = j.realityShortId;
      n.wsPath = j.wsPath;
      n.wsHost = j.wsHost;
      n.grpcServiceName = j.grpcServiceName;
      n.hyUp = j.hyUp ?? '';
      n.hyDown = j.hyDown ?? '';
      n.alpnList = j.alpnList ?? '';
      n.extraOpts = j.extraOpts ?? '';
      n.rawYaml = '';
      n.rawUri = j.rawUri;
      out.push(n);
    }
    if (skipped > 0) {
      AppLogger.warn(TAG, `ignored ${skipped} invalid node records`);
    }
    return out;
  }

  private async persist(): Promise<void> {
    if (this.store === null) {
      return;
    }
    // 凭据先写加密层（订阅 headerValue / 节点 rawUri 一次性绑定），再落元数据
    await this.storeCredentials();
    const subsJson: SubscriptionJson[] = [];
    for (const s of this.subscriptions) {
      subsJson.push(Subscription.toJson(s));
    }
    await this.store.put(KEY_SUBS, JSON.stringify(subsJson));
    await this.store.put(KEY_NODES, JSON.stringify(SubscriptionService.nodesToJson(this.nodes)));
    await this.store.put(KEY_HIDDEN, JSON.stringify(this.hiddenNodes));
    await this.store.flush();
  }

  /**
   * 敏感凭据落盘（透明写入路径）：节点凭据写 AssetStore；
   * 订阅 headerValue 同样入加密层，另存一次性绑定 rawUri 以便 Asset 缺失时回退。
   * Asset 不可用时绝不写明文，仅记录告警（元数据仍可正常持久化）。
   */
  private async storeCredentials(): Promise<void> {
    if (this.credStore === null) {
      return;
    }
    try {
      await CredentialStore.canonicalize(this.nodes, this.subscriptionCredentialSources(), false);
    } catch (e) {
      AppLogger.warn(TAG, `credential store write aborted: ${e instanceof Error ? e.message : String(e)}`);
      return;
    }
    const sealed = new Set<string>();
    const rawSealed = await this.credStore.get('sealed_node_keys_json', '[]') as string;
    for (const k of SubscriptionService.readJsonStringArray(rawSealed)) {
      sealed.add(k);
    }
    for (const n of this.nodes) {
      const id = nodeCredentialId(n);
      if (sealed.has(id) || n.rawUri.length === 0) {
        continue;
      }
      n.rawYaml = '';
      await this.credStore.put(nodeUriKey(id), n.rawUri);
    }
    await this.credStore.flush();
  }

  private subscriptionCredentialSources(): SubscriptionCredentialSource[] {
    const out: SubscriptionCredentialSource[] = [];
    for (const s of this.subscriptions) {
      if (s.headerValue.length === 0) {
        continue;
      }
      const src = new SubscriptionCredentialSource();
      src.id = s.id;
      src.headerValue = s.headerValue;
      out.push(src);
    }
    return out;
  }

  private static nodesToJson(nodes: ProxyNode[]): ProxyNodeJson[] {
    const out: ProxyNodeJson[] = [];
    for (const n of nodes) {
      out.push(ProxyNodeJson.fromNode(n));
    }
    return out;
  }

  async addSubscription(name: string, url: string, headerName: string, headerValue: string): Promise<Subscription> {
    const s = Subscription.newSubscription(util.generateRandomUUID(), name, url);
    s.headerName = headerName;
    s.headerValue = headerValue;
    s.sortOrder = this.subscriptions.length;
    this.subscriptions.push(s);
    await this.persist();
    AppLogger.info(TAG, `subscription added: ${s.name}`);
    return s;
  }

  async removeSubscription(id: string): Promise<void> {
    // 事务化快照以支持撤销
    this.undoSnapshot = new SubscriptionUndoSnapshot(this.subscriptions.slice(), this.nodes.slice());
    this.subscriptions = this.subscriptions.filter((s) => s.id !== id);
    this.nodes = this.nodes.filter((n) => n.subscriptionId !== id);
    await this.persist();
  }

  async undoRemove(): Promise<boolean> {
    if (this.undoSnapshot === null) {
      return false;
    }
    this.subscriptions = this.undoSnapshot.subs;
    this.nodes = this.undoSnapshot.nodes;
    this.undoSnapshot = null;
    await this.persist();
    return true;
  }

  async refreshSubscription(id: string): Promise<SubscriptionRefreshResult> {
    const sub = this.subscriptions.find((s) => s.id === id);
    if (sub === undefined) {
      return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.HTTP_ERROR, 'subscription not found');
    }
    // 本地 YAML 导入的伪订阅: 无网络源, 刷新按现有节点数报成功(幂等, 不打网络)
    if (sub.url.startsWith('local://')) {
      return SubscriptionRefreshResult.ok(this.nodesOf(id).length);
    }
    try {
      const fetched = await SubscriptionFetchPolicy.fetch(sub.url, sub.headerName, sub.headerValue);
      const body = fetched.body;
      sub.uploadBytes = fetched.userInfo.uploadBytes;
      sub.downloadBytes = fetched.userInfo.downloadBytes;
      sub.totalBytes = fetched.userInfo.totalBytes;
      sub.expireAt = fetched.userInfo.expireAt;

      // 自动命名：订阅仍是默认名（"订阅 N"）时，从内容中提取机场名
      if (SubscriptionService.isDefaultName(sub.name)) {
        const detected = SubscriptionService.detectProviderName(body);
        if (detected.length > 0) {
          sub.name = detected;
          AppLogger.info(TAG, `auto-named subscription to "${detected}"`);
        }
      }

      let parsed: ProxyNode[];
      YamlMerger.resetSkipStats();
      if (body.includes('proxies:')) {
        // Clash YAML 订阅：走合并引擎（跨刷新保留节点名称，限额与去重对齐 upstream）
        const prev = this.store !== null ? await this.store.get(`yaml_cache_${id}`, '') as string : '';
        const merged: MergedProxy[] = YamlMerger.merge([body], sub.name, prev);
        parsed = SubscriptionService.mergedToNodes(merged, sub.id);
        if (this.store !== null) {
          // 缓存只保存白名单结构化节点的安全 YAML，禁止缓存或回放订阅原文。
          await this.store.put(`yaml_cache_${id}`, YamlMerger.toYaml(merged));
        }
      } else {
        parsed = SubscriptionParser.parse(body, sub.id);
      }
      if (YamlMerger.lastSkippedCount > 0) {
        // 不再静默丢弃: 记录被跳过的节点数与协议类型, 供诊断与界面提示
        AppLogger.warn(TAG, `subscription ${id} skipped ${YamlMerger.lastSkippedCount} node(s) `
          + `of unsupported type(s): ${YamlMerger.lastSkippedTypes}`);
      }
      if (parsed.length === 0) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.PARSE_ERROR;
        await this.persist();
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PARSE_ERROR,
          '内容未解析出节点（支持 ss/ssr/vless/vmess/trojan/hysteria2/tuic/hysteria '
          + '与 Clash YAML）');
      }
      // 用户手动删除过的节点: 刷新后不再复活
      if (this.hiddenNodes.length > 0) {
        parsed = parsed.filter((n) => !this.hiddenNodes.includes(SubscriptionService.nodeKey(n)));
      }
      this.nodes = this.nodes.filter((n) => n.subscriptionId !== id).concat(parsed);
      this.ensureUniqueNames();
      sub.nodeCount = parsed.length;
      sub.lastFetchedAt = Date.now();
      sub.lastRefreshResult = SubscriptionRefreshStatus.OK;
      await this.persist();
      return SubscriptionRefreshResult.ok(parsed.length);
    } catch (e) {
      sub.lastRefreshResult = SubscriptionRefreshStatus.NETWORK_ERROR;
      await this.persist();
      const msg = e instanceof Error ? e.message : String(e);
      return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.NETWORK_ERROR, msg);
    }
  }

  /**
   * 导入本地 YAML 文件（订阅页"导入文件"入口）: 建 local:// 伪订阅,
   * 复用与网络订阅完全相同的解析链（Clash YAML proxies / base64 链接列表 /
   * 明文链接行, 含 hysteria2 全协议）。返回导入节点数, 0=解析失败。
   */
  async addLocalYaml(fileName: string, content: string): Promise<number> {
    const base = fileName.replace(/\.(ya?ml|txt)$/i, '');
    const trimmed = content.trim();
    if (trimmed.length === 0) {
      return 0;
    }
    const sub = Subscription.newSubscription(util.generateRandomUUID(),
      `本地:${base.length > 0 ? base : '订阅'}`, `local://${base}`);
    sub.sortOrder = this.subscriptions.length;
    let parsed: ProxyNode[];
    try {
      if (trimmed.includes('proxies:')) {
        const merged: MergedProxy[] = YamlMerger.merge([trimmed], sub.name, '');
        parsed = SubscriptionService.mergedToNodes(merged, sub.id);
        if (this.store !== null) {
          await this.store.put(`yaml_cache_${sub.id}`, YamlMerger.toYaml(merged));
        }
      } else {
        parsed = SubscriptionParser.parse(trimmed, sub.id);
      }
    } catch (e) {
      AppLogger.warn(TAG, `local yaml parse failed: ${e instanceof Error ? e.message : String(e)}`);
      return 0;
    }
    if (parsed.length === 0) {
      return 0;
    }
    if (this.hiddenNodes.length > 0) {
      parsed = parsed.filter((n) => !this.hiddenNodes.includes(SubscriptionService.nodeKey(n)));
    }
    this.subscriptions.push(sub);
    this.nodes = this.nodes.concat(parsed);
    this.ensureUniqueNames();
    sub.nodeCount = parsed.length;
    sub.lastFetchedAt = Date.now();
    sub.lastRefreshResult = SubscriptionRefreshStatus.OK;
    await this.persist();
    AppLogger.info(TAG, `local yaml imported: ${sub.name} (${parsed.length} nodes)`);
    return parsed.length;
  }

  nodesOf(subscriptionId: string): ProxyNode[] {
    return this.nodes.filter((n) => n.subscriptionId === subscriptionId);
  }

  findNode(id: string): ProxyNode | null {
    const n = this.nodes.find((x) => x.id === id);
    return n === undefined ? null : n;
  }

  /** 节点直链导入（对应 upstream SubscriptionAddStatus.singleNodeImported） */
  async addDirectNode(uri: string): Promise<number> {
    const node = ProxyNode.fromUri(uri, 'direct', util.generateRandomUUID());
    if (node === null) {
      return 0;
    }
    const key = `${node.server}:${node.port}:${node.type}`;
    const exists = this.nodes.some((n) => `${n.server}:${n.port}:${n.type}` === key);
    if (exists) {
      return -1;
    }
    this.nodes.push(node);
    this.ensureUniqueNames();
    await this.persist();
    return 1;
  }

  /** 更新订阅名称/URL（对应 upstream SubscriptionEditStatus.saved 持久化路径） */
  async updateSubscription(target: Subscription): Promise<void> {
    const index = this.subscriptions.findIndex((s) => s.id === target.id);
    if (index < 0) {
      return;
    }
    this.subscriptions[index] = target;
    await this.persist();
  }

  /** 判断是否为默认占位名（"订阅 N"） */
  static isDefaultName(name: string): boolean {
    return /^订阅\s*\d+$/.test(name.trim());
  }

  /**
   * 从订阅内容提取机场名（对齐常见订阅面板的 userinfo / 标题行约定）：
   * 1) Base64 整体解码后首行 `name=xxx` 或 `title=xxx`（V2Board 惯例）
   * 2) 解码后首行纯文本（非节点链接）视为品牌名，如 "吹雪云"
   * 3) Clash YAML 无用户信息头时返回 ''
   */
  static detectProviderName(body: string): string {
    let text = body;
    // 尝试整体 Base64 解码
    try {
      const cleaned = body.replace(/\s+/g, '');
      if (!/[:{]/.test(cleaned.substring(0, 200)) && /^[A-Za-z0-9+/=_-]+$/.test(cleaned)) {
        const decoded = SsrCodec.decodeBase64Url(cleaned);
        if (decoded.length > 0) {
          text = decoded;
        }
      }
    } catch (e) {
      // 保持原文
    }

    const lines = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
    if (lines.length === 0) {
      return '';
    }
    // 跳过 YAML/节点链接内容找头部信息行
    for (const line of lines.slice(0, 5)) {
      if (line.startsWith('ssr://') || line.startsWith('ss://') || line.startsWith('vless://')
        || line.startsWith('vmess://') || line.startsWith('trojan://')) {
        break; // 直接是节点列表，无头部
      }
      // name=xxx / title=xxx（URL 编码的中文需解码）
      const kv = line.match(/^(?:name|title)=(.+)$/i);
      if (kv !== null) {
        let val = kv[1].trim();
        try {
          val = decodeURIComponent(val);
        } catch (e) {
          // 已是明文
        }
        if (val.length > 0 && val.length <= 60) {
          return val;
        }
      }
      // 纯文本首行（含中文/字母，不含 yaml 冒号结构）视为品牌名
      if (!line.includes('://') && !line.startsWith('{') && !line.startsWith('-')
        && !/^[\w-]+\s*:/.test(line) && /[A-Za-z\u4e00-\u9fa5]/.test(line) && line.length <= 60) {
        return line;
      }
      break; // 首行不匹配即停止（YAML 等格式）
    }
    return '';
  }

  /** 判断是否为节点直链（与 ProxyNode.fromUri 支持的 scheme 一致） */
  static isNodeUri(input: string): boolean {
    const t = input.trim();
    return t.startsWith('ssr://') || t.startsWith('ss://') || t.startsWith('vless://')
      || t.startsWith('vmess://') || t.startsWith('trojan://') || t.startsWith('hysteria2://')
      || t.startsWith('hy2://');
  }
}

/** 手工节点的独立持久化桶（对应 node_edit_screen 手工添加） */
export class ManualNodeStore {
  private static store: preferences.Preferences | null = null;
  private static credStore: preferences.Preferences | null = null;
  private static nodes: ProxyNode[] = [];
  private static listeners: (() => void)[] = [];

  static async init(context: Context): Promise<void> {
    ManualNodeStore.store = await preferences.getPreferences(context, PREF_NAME);
    if (ManualNodeStore.credStore === null) {
      ManualNodeStore.credStore = await preferences.getPreferences(context, CRED_PREF_NAME);
    }
    ManualNodeStore.nodes = [];
    try {
      const raw = await ManualNodeStore.store.get('manual_nodes_json', '[]') as string;
      ManualNodeStore.nodes = SubscriptionService.mapNodes(JSON.parse(raw) as Object);
    } catch (e) {
      AppLogger.warn(TAG, 'invalid manual nodes preferences ignored');
    }
    // 手工节点同样走凭据分离：迁移 → 加密回填 → 清扫明文 → 落库
    await ManualNodeStore.migrateCredentials();
    CredentialStore.canonicalizeNodes(ManualNodeStore.nodes, false)
      .catch((e: Object) => AppLogger.warn(TAG, `manual node credential sync failed: ${e instanceof Error ? e.message : String(e)}`));
  }

  /** 手工节点一次性迁移（与订阅节点同一套 Asset 键空间，幂等） */
  private static async migrateCredentials(): Promise<void> {
    if (ManualNodeStore.nodes.length === 0) {
      return;
    }
    const report = await CredentialStore.canonicalizeNodes(ManualNodeStore.nodes, !CredentialStore.isFirstRun());
    if (report.failed > 0) {
      AppLogger.warn(TAG, `manual node credential migration incomplete: ${report.failed} field(s) failed; plaintext preserved`);
      return;
    }
    // 全部回读校验通过 → 清明文并落库（凭据已只存在于 AssetStore）
    for (const n of ManualNodeStore.nodes) {
      n.password = '';
      n.uuid = '';
      n.protocolParam = '';
      n.obfsParam = '';
      n.rawYaml = '';
      n.rawUri = '';
    }
    await ManualNodeStore.persist();
  }

  static all(): ProxyNode[] {
    return ManualNodeStore.nodes;
  }

  static async addNode(node: ProxyNode): Promise<void> {
    ManualNodeStore.nodes.push(node);
    await ManualNodeStore.persist();
    for (const l of ManualNodeStore.listeners) {
      l();
    }
  }

  static addListener(listener: () => void): void {
    ManualNodeStore.listeners.push(listener);
  }

  private static async persist(): Promise<void> {
    if (ManualNodeStore.store === null) {
      return;
    }
    // 凭据先入加密层，元数据 JSON 里的敏感字段已在 fromNode 中恒为空
    const report = await CredentialStore.canonicalizeNodes(ManualNodeStore.nodes, false);
    const out: ProxyNodeJson[] = [];
    for (const n of ManualNodeStore.nodes) {
      out.push(ProxyNodeJson.fromNode(n));
    }
    await ManualNodeStore.store.put('manual_nodes_json', JSON.stringify(out));
    await ManualNodeStore.store.flush();
    if (report.failed > 0) {
      AppLogger.warn(TAG, `manual node credential store incomplete: ${report.failed} field(s)`);
    }
  }
}

/** 撤销快照（对应 subscription_undo_record.dart） */
export class SubscriptionUndoSnapshot {
  subs: Subscription[];
  nodes: ProxyNode[];

  constructor(subs: Subscription[], nodes: ProxyNode[]) {
    this.subs = subs;
    this.nodes = nodes;
  }
}

/** 持久化 JSON 形状（显式类，满足 arkts-no-untyped-obj-literals） */
export class ProxyNodeJson {
  id: string = '';
  subscriptionId: string = '';
  name: string = '';
  server: string = '';
  port: number = 0;
  password: string = '';
  method: string = '';
  protocol: string = '';
  protocolParam: string = '';
  obfs: string = '';
  obfsParam: string = '';
  type: string = 'ssr';
  proxyType: string = '';
  uuid: string = '';
  alterId: number = 0;
  udp: boolean = false;
  network: string = '';
  tls: boolean = false;
  servername: string = '';
  skipCertVerify: boolean = false;
  flow: string = '';
  clientFingerprint: string = '';
  realityPublicKey: string = '';
  realityShortId: string = '';
  wsPath: string = '';
  wsHost: string = '';
  grpcServiceName: string = '';
  /** hysteria2 扩展字段（可选: 旧存储无这些键, 读取端 ?? '' 兜底） */
  hyUp?: string;
  hyDown?: string;
  alpnList?: string;
  /** 结构化槽位之外的额外键值(JSON 数组)，旧存储无此键，读取端 ?? '' 兜底 */
  extraOpts?: string;
  rawYaml: string = '';
  rawUri: string = '';

  static fromNode(n: ProxyNode): ProxyNodeJson {
    const j = new ProxyNodeJson();
    j.id = n.id;
    j.subscriptionId = n.subscriptionId;
    j.name = n.name;
    j.server = n.server;
    j.port = n.port;
    j.password = n.password;
    j.method = n.method;
    j.protocol = n.protocol;
    j.protocolParam = n.protocolParam;
    j.obfs = n.obfs;
    j.obfsParam = n.obfsParam;
    j.type = n.type === ProxyNodeType.SS ? 'ss' : (n.type === ProxyNodeType.SSR ? 'ssr' : 'other');
    j.proxyType = n.proxyType;
    j.uuid = n.uuid;
    j.alterId = n.alterId;
    j.udp = n.udp;
    j.network = n.network;
    j.tls = n.tls;
    j.servername = n.servername;
    j.skipCertVerify = n.skipCertVerify;
    j.flow = n.flow;
    j.clientFingerprint = n.clientFingerprint;
    j.realityPublicKey = n.realityPublicKey;
    j.realityShortId = n.realityShortId;
    j.wsPath = n.wsPath;
    j.wsHost = n.wsHost;
    j.grpcServiceName = n.grpcServiceName;
    j.hyUp = n.hyUp;
    j.hyDown = n.hyDown;
    j.alpnList = n.alpnList;
    j.extraOpts = n.extraOpts;
    j.rawYaml = '';
    j.rawUri = n.rawUri;
    return j;
  }
}

/** 持久化 JSON 形状 */
export class SubscriptionJson {
  id: string = '';
  name: string = '';
  url: string = '';
  headerName: string = '';
  headerValue: string = '';
  lastFetchedAt: number = 0;
  lastRefreshResult: string = '';
  nodeCount: number = 0;
  uploadBytes?: number;
  downloadBytes?: number;
  totalBytes?: number;
  expireAt?: number;
  enabled: boolean = true;
  sortOrder: number = 0;
}
