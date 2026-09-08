/**
 * 订阅服务：增删改查 + 刷新 + 撤销；手工节点独立存储（ManualNodeStore）
 * 移植自 upstream: SSRVPN_Android/lib/services/subscription_service.dart
 *                packages/ssrvpn_shared/lib/services/subscription_service_*.dart
 *                subscription_processing.dart / subscription_undo_record.dart
 */
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { Subscription, SubscriptionRefreshResult, SubscriptionRefreshStatus } from '../models/Subscription';
import { ProxyNode, ProxyNodeType, SsrCodec } from '../models/ProxyNode';
import { SubscriptionParser } from './SubscriptionParser';
import { SubscriptionFetchPolicy } from './SubscriptionFetchPolicy';
import { YamlMerger, MergedProxy } from './YamlMerger';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'SubscriptionService';
const PREF_NAME = 'ssrvpn_subscriptions';
const KEY_SUBS = 'subscriptions_json';
const KEY_NODES = 'nodes_json';

export class SubscriptionService {
  private store: preferences.Preferences | null = null;
  subscriptions: Subscription[] = [];
  nodes: ProxyNode[] = [];
  /** 撤销记录（对应 subscription_undo_record.dart）：最近一次删除的订阅与节点 */
  private undoSnapshot: SubscriptionUndoSnapshot | null = null;

  async init(context: Context): Promise<void> {
    this.store = await preferences.getPreferences(context, PREF_NAME);
    this.subscriptions = [];
    this.nodes = [];

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

    AppLogger.info(TAG, `loaded ${this.subscriptions.length} subscriptions, ${this.nodes.length} nodes`);
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
    const subsJson: SubscriptionJson[] = [];
    for (const s of this.subscriptions) {
      subsJson.push(Subscription.toJson(s));
    }
    await this.store.put(KEY_SUBS, JSON.stringify(subsJson));
    await this.store.put(KEY_NODES, JSON.stringify(SubscriptionService.nodesToJson(this.nodes)));
    await this.store.flush();
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
    try {
      const body = await SubscriptionFetchPolicy.fetch(sub.url, sub.headerName, sub.headerValue);

      // 自动命名：订阅仍是默认名（"订阅 N"）时，从内容中提取机场名
      if (SubscriptionService.isDefaultName(sub.name)) {
        const detected = SubscriptionService.detectProviderName(body);
        if (detected.length > 0) {
          sub.name = detected;
          AppLogger.info(TAG, `auto-named subscription to "${detected}"`);
        }
      }

      let parsed: ProxyNode[];
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
      if (parsed.length === 0) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.PARSE_ERROR;
        await this.persist();
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PARSE_ERROR,
          '内容未解析出节点（支持 ss/ssr/vless/vmess/trojan 与 Clash YAML）');
      }
      this.nodes = this.nodes.filter((n) => n.subscriptionId !== id).concat(parsed);
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
    await this.persist();
    return 1;
  }

  /** 更新订阅名称/URL（对应 upstream SubscriptionEditStatus.saved 持久化路径） */
  async updateSubscription(target: Subscription): Promise<void> {
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
  private static nodes: ProxyNode[] = [];
  private static listeners: (() => void)[] = [];

  static async init(context: Context): Promise<void> {
    ManualNodeStore.store = await preferences.getPreferences(context, PREF_NAME);
    ManualNodeStore.nodes = [];
    try {
      const raw = await ManualNodeStore.store.get('manual_nodes_json', '[]') as string;
      ManualNodeStore.nodes = SubscriptionService.mapNodes(JSON.parse(raw) as Object);
    } catch (e) {
      AppLogger.warn(TAG, 'invalid manual nodes preferences ignored');
    }
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
    const out: ProxyNodeJson[] = [];
    for (const n of ManualNodeStore.nodes) {
      out.push(ProxyNodeJson.fromNode(n));
    }
    await ManualNodeStore.store.put('manual_nodes_json', JSON.stringify(out));
    await ManualNodeStore.store.flush();
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
  enabled: boolean = true;
  sortOrder: number = 0;
}
