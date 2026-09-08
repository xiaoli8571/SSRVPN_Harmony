/**
 * 连接编排器：管理连接状态机、VPN 能力拉起、Clash API 就绪等待
 * 移植自 upstream: SSRVPN_Android/lib/services/connection_orchestrator.dart
 *                packages/ssrvpn_shared/lib/utils/connection_intent_tracker.dart
 *                connection_transition_queue.dart / core_recovery_policy.dart
 *
 * 链路（API 26 实测形态）：
 *   connect() → 写 Mihomo YAML 到 cacheDir → startVpnExtensionAbility(want.parameters.configPath)
 *   → VpnExtensionAbility：create() 得到 TUN fd → coreBridge.attachTun + startCore
 *   → 本编排器轮询 Clash API 就绪 → selectNode → CONNECTED
 */
import { vpnExtension, http } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import { fileIo as fs } from '@kit.CoreFileKit';
import { notificationManager } from '@kit.NotificationKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { coreBridge } from '../../core/CoreBridge';
import { ClashApiService, TrafficSnapshot } from './ClashApiService';
import { ClashConfigGenerator } from './ClashConfigGenerator';
import { Ipv6Detector } from './Ipv6Detector';
import { DoHResolver } from './DoHResolver';
import { SubscriptionService } from './SubscriptionService';
import { SettingsService, ConnectionSnapshot } from './SettingsService';
import { SsrvpnNotifier } from './SsrvpnNotifier';
import { AppSettings } from '../models/AppSettings';
import { ProxyNode } from '../models/ProxyNode';
import { AppDiagnostics } from '../models/PublicIpInfo';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'ConnectionOrchestrator';
const MIXED_PORT = 7890;
const API_PORT = 9090;
const CONFIG_FILE = 'mihomo_config.yaml';
const START_ERROR_FILE = 'vpn_start_error.txt';
const START_OK_FILE = 'vpn_start_ok.txt';
/** 扩展进程心跳文件（内核运行期间每 3s 覆写时间戳） */
const HEARTBEAT_FILE = 'vpn_heartbeat.txt';
/** 心跳超过该时长视为内核死亡（ms） */
const HEARTBEAT_STALE_MS = 15000;

export enum ConnState {
  DISCONNECTED = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  DISCONNECTING = 3,
  RECOVERING = 4
}

export class ConnectionOrchestrator {
  /**
   * 进程级单例: 每个页面必须共享同一个 orchestrator 实例。
   * 此前各页面各 new 一个, 新实例 state 永远是 DISCONNECTED —— 切换页面时
   * 主页 onPageShow 误判"未连接"触发重连, 且 connect() 每次生成新 API secret,
   * 其他页面持有的旧 secret 全部 401(延迟测试"超时"的根因)。
   */
  private static shared: ConnectionOrchestrator | null = null;

  static instance(): ConnectionOrchestrator {
    if (ConnectionOrchestrator.shared === null) {
      ConnectionOrchestrator.shared = new ConnectionOrchestrator();
    }
    return ConnectionOrchestrator.shared;
  }

  state: ConnState = ConnState.DISCONNECTED;
  traffic: TrafficSnapshot = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
  publicIp: string = '';
  startedAt: number = 0;
  lastError: string = '';
  api: ClashApiService = new ClashApiService();
  /** 本次连接是否启用 IPv6 入站（连接时探测, 无 IPv6 环境自动绕过） */
  ipv6Active: boolean = false;
  private monitorTimer: number = -1;
  private trafficTimer: number = -1;
  private connectSeq: number = 0; // 启动代际门控（对应 StartGenerationGate）
  private context: Context | null = null;
  private apiSecret: string = '';
  private lastSubs: SubscriptionService | null = null;
  private lastNode: ProxyNode | null = null;
  private recoveryAttempts: number = 0; // 内核恢复退避计数（对应 core_recovery_policy）
  private lastNodeName: string = '';

  listeners: (() => void)[] = [];
  notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  init(context: Context): void {
    this.context = context;
  }

  /** 配置变更后自动重启隧道：仅当前处于已连接/连接中时才断开并用同一节点重连
   *  （重连会重新生成含新 mode/规则/hosts 的 YAML 并重建带新 blockedApplications 的 TUN）。
   *  未连接时不动 —— 下次手动连接自然带上最新配置。 */
  private restarting: boolean = false;
  async restartIfConnected(reason: string): Promise<boolean> {
    if (this.state !== ConnState.CONNECTED && this.state !== ConnState.CONNECTING) {
      return false;
    }
    if (this.restarting) {
      return false; // 已有重启在途, 忽略重复触发(防抖)
    }
    const subs = this.lastSubs;
    const node = this.lastNode;
    if (subs === null || node === null) {
      return false;
    }
    this.restarting = true;
    AppLogger.info(TAG, `auto-restart (${reason}): 断开并重连以应用新配置`);
    try {
      await this.disconnect();
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 600));
      const ok = await this.connect(node, subs);
      AppLogger.info(TAG, `auto-restart (${reason}) 完成, 结果=${ok}`);
      return ok;
    } finally {
      this.restarting = false;
    }
  }

  /** 运行时切换代理模式：模式写在 YAML 里, 需重建隧道生效(自动断开重连)。 */
  async applyProxyMode(mode: string): Promise<void> {
    await this.restartIfConnected('proxyMode=' + mode);
  }

  /** 读取 VPN Extension 进程回写的启动错误（跨进程文件通道） */
  private readStartError(): string {
    if (this.context === null) {
      return '';
    }
    try {
      const path = `${this.context.cacheDir}/${START_ERROR_FILE}`;
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf)).trim();
    } catch (e) {
      return '';
    }
  }

  private clearStartError(): void {
    if (this.context === null) {
      return;
    }
    try {
      fs.unlinkSync(`${this.context.cacheDir}/${START_ERROR_FILE}`);
    } catch (e) {
      // 文件不存在属正常
    }
    try {
      fs.unlinkSync(`${this.context.cacheDir}/${START_OK_FILE}`);
    } catch (e) {
      // 文件不存在属正常
    }
  }

  /** 扩展进程是否已回写启动成功标记（statSync 比 accessSync 行为更可靠） */
  private readStartOk(): boolean {
    if (this.context === null) {
      return false;
    }
    try {
      fs.statSync(`${this.context.cacheDir}/${START_OK_FILE}`);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 读取扩展进程心跳距今毫秒数；-1 = 无心跳/读取失败 */
  private readHeartbeatAge(): number {
    if (this.context === null) {
      return -1;
    }
    try {
      const path = `${this.context.cacheDir}/${HEARTBEAT_FILE}`;
      const stat = fs.statSync(path);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const size = stat.size > 0 ? stat.size : 32;
      const buf = new ArrayBuffer(size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const raw = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf)).trim();
      const ts = Number(raw);
      if (!Number.isFinite(ts) || ts <= 0) {
        return -1;
      }
      return Date.now() - ts;
    } catch (e) {
      return -1;
    }
  }

  /** 内核存活判定：扩展进程心跳新鲜即存活（UI 进程的 coreBridge 实例与扩展进程无关，不可用） */
  private isCoreAliveByHeartbeat(): boolean {
    const age = this.readHeartbeatAge();
    return age >= 0 && age < HEARTBEAT_STALE_MS;
  }

  async connect(node: ProxyNode, subs: SubscriptionService): Promise<boolean> {
    const seq = ++this.connectSeq;
    this.state = ConnState.CONNECTING;
    this.lastError = '';
    this.lastSubs = subs;
    this.lastNodeName = node.name;
    this.notify();

    try {
      if (this.context === null) {
        throw new Error('orchestrator 未初始化（init(context) 缺失）');
      }
      const settings: AppSettings = await SettingsService.load();

      // 节点有效性检查：旧版本持久化的节点缺 rawYaml 且非 ss/ssr 字段不完整时无法生成配置。
      // 自动降级到第一个可用节点；全部无效时自动刷新一次订阅（修复升级后旧数据不可用）。
      const isValidNode = (n: ProxyNode): boolean => ClashConfigGenerator.proxyYamlLine(n).length > 0;
      let target: ProxyNode = node;
      if (!isValidNode(target)) {
        const firstValid = subs.nodes.find((n) => isValidNode(n)) ?? null;
        if (firstValid !== null) {
          target = firstValid;
          AppLogger.warn(TAG, `preferred node invalid; fall back to ${target.name}`);
        } else {
          AppLogger.warn(TAG, 'no valid node config; auto-refreshing subscriptions');
          for (const s of subs.subscriptions) {
            try {
              await subs.refreshSubscription(s.id);
            } catch (e) {
              AppLogger.warn(TAG, `auto refresh ${s.name} failed: ${e instanceof Error ? e.message : String(e)}`);
            }
          }
          const retry = subs.nodes.find((n) => isValidNode(n)) ?? null;
          if (retry === null) {
            throw new Error('订阅节点配置无效：请到「订阅」页点击「全部刷新」，确认节点已成功导入后再连接');
          }
          target = retry;
        }
      }
      this.lastNodeName = target.name;
      this.lastNode = target;

      // API secret 保持稳定(首次生成后复用): 每次重连都换 secret 会让其他页面
      // 持有的旧 secret 全部 401, 延迟测试/节点切换集体失败(表现全是"超时")。
      const savedSecret = await SettingsService.getApiSecret();
      if (savedSecret.length > 0) {
        this.apiSecret = savedSecret;
      } else {
        const random = cryptoFramework.createRandom();
        const randomBlob = await random.generateRandom(24);
        let randomHex = '';
        for (const value of randomBlob.data) {
          randomHex += value.toString(16).padStart(2, '0');
        }
        this.apiSecret = `ssr-${randomHex}`;
        await SettingsService.setApiSecret(this.apiSecret);
      }

      // 关键：扩展进程存活时再次 startVpnExtensionAbility 只会累加 startId，
      // 系统不会重新回调 onCreate（TUN/内核启动逻辑不会重放）。
      // 因此每次连接前先停掉既有 VPN 扩展（触发 onDestroy → 内核停止），
      // 等待进程退出后重新拉起，保证新配置/新节点真正生效。
      // 注意: 停旧隧道也必须在 IPv6 探测之前 —— 隧道存活时 ::/0 路由指向
      // 隧道自身, 探测会误报"有 IPv6"。
      try {
        const stopWant: Want = {
          bundleName: 'com.ssrvpn.client',
          abilityName: 'VpnExtensionAbility'
        };
        await vpnExtension.stopVpnExtensionAbility(stopWant);
      } catch (e) {
        // 未运行时停止会报错，属正常
      }
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 800));

      // IPv6 入站环境探测（FlClash 等主流客户端语义）: 当前网络确实有 IPv6 出口
      // 才开双栈; 无 IPv6 环境自动绕过(纯 IPv4), 避免 ::/0 + fake-ip6 把
      // IPv6-preferred 应用(YouTube 等)引上死路。
      this.ipv6Active = await Ipv6Detector.hasIPv6();

      // geoip.metadb 缺失时降级生成（不含 GEOIP 规则）, 避免内核在 config.Parse
      // 阶段联网下载 MMDB 失败导致启动卡死; 连接成功后后台补齐, 下次连接生效。
      const geoipPath = `${this.context.cacheDir}/geoip.metadb`;
      let useGeoip = false;
      try {
        useGeoip = fs.statSync(geoipPath).size > 0;
      } catch (e) {
        useGeoip = false;
      }
      if (!useGeoip) {
        AppLogger.info(TAG, 'geoip.metadb missing; generate config without GEOIP rule');
      }

      // ── 代理服务器域名防投毒解析(UI 进程, 此刻 VPN 未起、网络干净) ──
      // 明文 UDP DNS 会往代理域名的应答里追加假记录, 内核拨假地址全线超时。
      // 用 DoH 预解析所有节点入口域名(与权威应答验证一致), 结果写进 YAML hosts:,
      // 内核直接命中真实 IP。带缓存 + 6s 全局预算 + 失败二轮重试。
      const serverDomains: string[] = [];
      for (const n of subs.nodes) {
        const s = n.server;
        if (s.length === 0 || s.includes(':') || /^\d+\.\d+\.\d+\.\d+$/.test(s)) {
          continue; // 跳过空/IPv6/裸 IPv4
        }
        serverDomains.push(s);
      }
      let proxyHosts: Record<string, string> = {};
      try {
        proxyHosts = await DoHResolver.resolveMany(serverDomains, 6000);
      } catch (e) {
        AppLogger.warn(TAG, `DoH pre-resolve failed: ${e instanceof Error ? e.message : String(e)}`);
      }
      AppLogger.info(TAG, `DoH pinned ${Object.keys(proxyHosts).length}/${serverDomains.length} proxy servers`);
      const unpinnedDomains: string[] = [];
      for (const d of serverDomains) {
        if (proxyHosts[d.toLowerCase()] === undefined) {
          unpinnedDomains.push(d);
        }
      }
      if (unpinnedDomains.length > 0) {
        // 未 pin 的域名运行期回退 proxy-server-nameserver(明文 UDP, 有被投毒风险),
        // 点名记录便于排查"个别节点不通"类问题。
        AppLogger.warn(TAG, `unpinned servers: ${unpinnedDomains.slice(0, 12).join(', ')}`);
      }

      const yaml = ClashConfigGenerator.generate(target, subs.nodes, settings, MIXED_PORT, API_PORT,
        this.apiSecret, useGeoip, this.ipv6Active, proxyHosts);
      const configPath = `${this.context.cacheDir}/${CONFIG_FILE}`;
      const file = fs.openSync(configPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, yaml);
      } finally {
        fs.closeSync(file);
      }
      AppLogger.info(TAG, `config written: ${configPath} (${yaml.length} bytes)`);
      this.clearStartError();

      // 拉起 VPN 能力（首次会弹系统 VPN 授权框）；TUN 建立 + 内核启动都在扩展进程完成。
      // 扩展进程把启动结果写入 vpn_start_error.txt（空文件/不存在 = 成功，非空 = 失败原因），
      // 并写入 vpn_start_ok.txt 成功标记 —— UI 进程通过文件轮询确认，绕开跨进程 loopback 探测的不确定性。
      // ipv6Inbound 标志同步 VpnConfig 的双栈开关, 与 YAML 保持一致。
      // bypassPackages: 强制不走代理的应用包名(VpnConfig.blockedApplications,
      //   框架层直接让这些 App 的流量绕过隧道走物理网络)。
      const want: Want = {
        bundleName: 'com.ssrvpn.client',
        abilityName: 'VpnExtensionAbility',
        parameters: {
          configPath: configPath,
          ipv6Inbound: this.ipv6Active ? 1 : 0,
          bypassPackages: settings.excludedApps.join(',')
        }
      };
      await vpnExtension.startVpnExtensionAbility(want);

      this.api.resetTrafficBaseline();
      this.api.setEndpoint(API_PORT, this.apiSecret);
      const deadline = Date.now() + 30000;
      let apiReady = false;
      while (Date.now() < deadline) {
        if (seq !== this.connectSeq) {
          await this.disconnectInternal();
          return false;
        }
        // 1) 失败信号优先：扩展进程回写的错误
        const extErr = this.readStartError();
        if (extErr.length > 0) {
          throw new Error(`Clash 内核启动失败: ${extErr}`);
        }
        // 2) 成功信号：扩展回写 OK 标记，且 loopback 探测通过（此时接口必然已绑定）
        if (this.readStartOk() && await this.api.healthProbe()) {
          apiReady = true;
          break;
        }
        await new Promise<void>((resolve) => setTimeout(() => resolve(), 300));
      }
      if (!apiReady) {
        const extErr = this.readStartError();
        if (extErr.length > 0) {
          throw new Error(`Clash 内核启动失败: ${extErr}`);
        }
        if (this.readStartOk()) {
          throw new Error('内核已启动但 API 探测失败：9090 端口跨进程不可达，请反馈日志');
        }
        throw new Error('Clash API 未就绪（30s 超时）：VPN 扩展未上报启动结果，请重试或反馈日志');
      }

      // 选中节点
      const selected = await this.api.selectNode(target.name);
      if (!selected) {
        AppLogger.warn(TAG, `selectNode(${target.name}) failed; keep default PROXY first node`);
      }

      if (seq !== this.connectSeq) {
        await this.disconnectInternal();
        return false; // 已被更新的连接请求取代
      }

      this.state = ConnState.CONNECTED;
      this.startedAt = Date.now();
      this.recoveryAttempts = 0;
      this.startMonitors();
      this.clearStartError(); // 连接成功，清掉启动标记文件
      // 连接快照：重启/崩溃后恢复连接意图（对应 NativeConnectionSnapshotStore）
      const snap = new ConnectionSnapshot();
      snap.desiredConnected = true;
      snap.nodeName = target.name;
      snap.savedAt = Date.now();
      await SettingsService.saveSnapshot(snap);
      await SsrvpnNotifier.update('SSRVPN 已连接', target.name, '↓ 0 B/s  ↑ 0 B/s');
      this.notify();
      AppLogger.info(TAG, `connected to node ${target.name}`);
      if (!useGeoip) {
        // 后台补齐 geoip.metadb（jsdelivr 镜像）, 下次连接即可启用 GEOIP 直连规则
        this.downloadGeoipInBackground();
      }
      return true;
    } catch (e) {
      const errorMessage = e instanceof Error ? e.message : String(e);
      try {
        await this.disconnectInternal();
      } catch (cleanupError) {
        AppLogger.warn(TAG, `connect rollback failed: ${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`);
      }
      this.state = ConnState.DISCONNECTED;
      this.startedAt = 0;
      this.ipv6Active = false;
      this.traffic = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
      this.api.resetTrafficBaseline();
      this.api.setEndpoint(API_PORT, '');
      this.lastError = errorMessage;
      this.notify();
      AppLogger.error(TAG, `connect failed: ${errorMessage}`);
      return false;
    }
  }

  async disconnect(): Promise<void> {
    const seq = ++this.connectSeq;
    this.state = ConnState.DISCONNECTING;
    this.notify();
    await this.disconnectInternal();
    if (seq !== this.connectSeq) {
      return;
    }
    this.state = ConnState.DISCONNECTED;
    this.traffic = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
    this.api.resetTrafficBaseline();
    this.notify();
    AppLogger.info(TAG, 'disconnected');
  }

  /** 后台下载 geoip.metadb 到内核 home 目录（cacheDir），成功后下次连接启用 GEOIP 直连规则 */
  private geoipDownloading: boolean = false;

  private downloadGeoipInBackground(): void {
    if (this.geoipDownloading || this.context === null) {
      return;
    }
    this.geoipDownloading = true;
    const ctx = this.context;
    // jsdelivr CDN 镜像（GitHub release 直连国内不可达），多镜像依次回退
    const mirrors: string[] = [
      'https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb',
      'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb',
      'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb'
    ];
    const tryMirror = (idx: number): void => {
      if (idx >= mirrors.length) {
        this.geoipDownloading = false;
        AppLogger.warn(TAG, 'geoip.metadb download failed from all mirrors; will retry on next connect');
        return;
      }
      const client = http.createHttp();
      client.request(mirrors[idx], {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 90000
      }).then((resp: http.HttpResponse) => {
        const buf = resp.result as ArrayBuffer;
        if (resp.responseCode === 200 && buf.byteLength > 1024 * 100) {
          const file = fs.openSync(`${ctx.cacheDir}/geoip.metadb`,
            fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(file.fd, buf);
          } finally {
            fs.closeSync(file);
          }
          this.geoipDownloading = false;
          client.destroy();
          AppLogger.info(TAG, `geoip.metadb downloaded (${buf.byteLength} bytes); GEOIP rule enabled next connect`);
        } else {
          client.destroy();
          AppLogger.warn(TAG, `geoip mirror ${idx} returned ${resp.responseCode}, size ${buf.byteLength}`);
          tryMirror(idx + 1);
        }
      }).catch((e: Object) => {
        client.destroy();
        AppLogger.warn(TAG, `geoip mirror ${idx} failed: ${e}`);
        tryMirror(idx + 1);
      });
    };
    tryMirror(0);
  }

  private async disconnectInternal(): Promise<void> {
    this.stopMonitors();
    const snap = new ConnectionSnapshot();
    snap.desiredConnected = false;
    snap.savedAt = Date.now();
    await SettingsService.saveSnapshot(snap);
    try {
      await coreBridge.stopCore();
    } catch (e) {
      AppLogger.warn(TAG, `stopCore error: ${e}`);
    }
    if (this.context === null) {
      return;
    }
    try {
      const want: Want = {
        bundleName: 'com.ssrvpn.client',
        abilityName: 'VpnExtensionAbility'
      };
      await vpnExtension.stopVpnExtensionAbility(want);
    } catch (e) {
      AppLogger.warn(TAG, `stopVpnExtensionAbility error: ${e}`);
    }
  }

  /** 存活监控 + 流量轮询 + 常驻通知（对应 CoreLivenessMonitor / VpnTrafficTracker / NotificationUpdatePolicy） */
  private startMonitors(): void {
    this.stopMonitors();
    this.monitorTimer = setInterval(() => {
      // 内核跑在 VPN 扩展进程里，UI 进程的 coreBridge.isCoreAlive() 永远为 false，
      // 只能依据扩展进程心跳文件判断存活（心跳新鲜 = 内核活着）。
      const alive = this.isCoreAliveByHeartbeat();
      if (!alive && this.state === ConnState.CONNECTED) {
          // 内核死亡：按 core_recovery_policy 自动重连（最多 2 次，之后放弃）
          this.state = ConnState.RECOVERING;
          this.notify();
          AppLogger.warn(TAG, `core died; recovery attempt ${this.recoveryAttempts + 1}`);
          if (this.recoveryAttempts < 2 && this.lastSubs !== null) {
            this.recoveryAttempts = this.recoveryAttempts + 1;
            const name = this.lastNodeName;
            const node = this.lastSubs.nodes.find((n) => n.name === name)
              ?? (this.lastSubs.nodes.length > 0 ? this.lastSubs.nodes[0] : null);
            if (node !== null) {
              this.connect(node, this.lastSubs);
              return;
            }
          }
          this.state = ConnState.DISCONNECTED;
          this.lastError = '内核异常退出，自动恢复失败，请手动重连';
          this.notify();
        }
    }, 3000);
    this.trafficTimer = setInterval(() => {
      this.api.traffic().then((t: TrafficSnapshot) => {
        this.traffic = t;
        if (this.state === ConnState.CONNECTED) {
          SsrvpnNotifier.update('SSRVPN 已连接',
            this.lastNodeName.length > 0 ? this.lastNodeName : '已连接',
            `↓ ${this.formatSpeed(t.downloadSpeed)}  ↑ ${this.formatSpeed(t.uploadSpeed)}`);
        }
        this.notify();
      });
    }, 1000);
  }

  private stopMonitors(): void {
    if (this.monitorTimer >= 0) {
      clearInterval(this.monitorTimer);
      this.monitorTimer = -1;
    }
    if (this.trafficTimer >= 0) {
      clearInterval(this.trafficTimer);
      this.trafficTimer = -1;
    }
  }

  async diagnostics(): Promise<AppDiagnostics> {
    const d = new AppDiagnostics();
    d.coreRunning = this.state === ConnState.CONNECTED;
    d.vpnActive = this.state === ConnState.CONNECTED;
    d.clashApiReachable = await this.api.healthProbe();
    d.clashApiPort = API_PORT;
    d.startedAt = this.startedAt;
    d.uptimeSeconds = this.startedAt > 0 ? Math.floor((Date.now() - this.startedAt) / 1000) : 0;
    d.lastError = this.lastError;
    return d;
  }

  formatSpeed(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${bytesPerSecond.toFixed(0)} B/s`;
    }
    if (bytesPerSecond < 1024 * 1024) {
      return `${(bytesPerSecond / 1024).toFixed(1)} KB/s`;
    }
    return `${(bytesPerSecond / 1024 / 1024).toFixed(2)} MB/s`;
  }

  formatBytes(total: number): string {
    if (total < 1024) {
      return `${total} B`;
    }
    if (total < 1024 * 1024) {
      return `${(total / 1024).toFixed(1)} KB`;
    }
    if (total < 1024 * 1024 * 1024) {
      return `${(total / 1024 / 1024).toFixed(1)} MB`;
    }
    return `${(total / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }
}
