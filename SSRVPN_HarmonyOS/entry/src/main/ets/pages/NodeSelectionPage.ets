/**
 * 节点选择页 — 对齐 upstream SsrvpnNodeSelectionPage + _NodeSelectionCard
 * 顶栏(返回/标题/测全部) + 订阅筛选 chips + 节点卡列表（旗帜/名称/延迟按钮/选中勾）。
 */
import { router, promptAction } from '@kit.ArkUI';
import { Ui, LatencyStyle, NodeDisplay } from '../theme/UiTokens';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { Subscription, SubscriptionRefreshStatus } from '../commons/models/Subscription';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ProxyNode } from '../commons/models/ProxyNode';
import { LatencyController } from '../commons/services/LatencyController';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { DirectLatencyTester } from '../commons/services/DirectLatencyTester';
import { NodeCountryPolicy } from '../commons/services/PublicIpService';
import { AppLogger } from '../commons/utils/AppLogger';
import {
  NodeSortSnapshot, NodeSortModes, NodeLatencyRecord, NodeProtocolPolicy
} from '../commons/services/NodeSortPersistence';
import { NodeCandidate, scoreOf } from '../commons/services/SmartSelector';
import { CountryFlagIcon } from '../widgets/CountryFlagIcon';

const TAG = 'NodeSelectionPage';

/**
 * 快速批量测速并发度：10 路。
 * 上限来自「内核单实例争抢」而非 CPU：每条 /proxies/{name}/delay 都会让 mihomo
 * 现起一次真实出站连接，过高并发会互相挤占同一内核的 DNS/握手资源、把延迟打高。
 * 用户更关注快速返回和大致排序。10 路比 12 路保留少量资源余量，同时显著缩短
 * 大订阅的整轮耗时。首轮失败仍会进行一次短时低压力复测，控制假超时。
 */
const BATCH_LANES = 8;
/**
 * 批量测速单节点超时（毫秒）。真机快照里存活节点的实测延迟分布在 39~841ms，
 * 快速模式只需要用于相对排序的近似结果：首轮 1800ms 足以覆盖常见可用节点，
 * 慢节点和瞬时失败节点随后再用 2200ms 快速复测一次。
 */
const BATCH_NODE_TIMEOUT_MS = 1500;
/** 单节点手动测速保留原来的宽松超时（用户只等一个节点，优先给足机会成功） */
const SINGLE_NODE_TIMEOUT_MS = 5000;
/** 可靠测速地址按顺序回退；每个 URL 只尝试一次，且共享单节点总预算。 */
const LATENCY_FALLBACK_URLS: string[] = [
  'https://cp.cloudflare.com/generate_204',
  'https://www.gstatic.com/generate_204'
];
/**
 * 离开节点页后「宽限回收测速内核」的等待时长（毫秒）。
 * 测速内核启动链路包含 DoH 预解析 + 停旧扩展 + 600ms 等待 + 启新扩展 + 健康轮询，
 * 每次重建都要用户再等一两秒。90s 内来回切页面/连点测速复用同一内核，
 * 超过则回收，避免临时进程在后台长期常驻。
 */
const TEST_CORE_KEEP_ALIVE_MS = 90000;
/** 测速通道：内核（真实协议栈）/ 直连探测兜底 */
const CHANNEL_KERNEL = 'kernel';
const CHANNEL_DIRECT = 'direct';

interface NodeRow {
  node: ProxyNode;
  countryCode: string;
  /** 综合评分/状态（来自持久化测速快照；无数据时 hasData=false） */
  status: NodeStatusView;
}

/**
 * 节点状态视图（第三轮 UI）：由持久化快照派生，纯展示用。
 *  - hasData: 快照中存在该节点且非「未测」
 *  - rateLabel: 近期成功率文本，如 "100%"
 *  - failCount: 连续失败次数
 *  - score: SmartSelector 综合评分（越小越好，ms 等价）
 */
class NodeStatusView {
  hasData: boolean = false;
  rateLabel: string = '';
  failCount: number = 0;
  score: number = 0;
}

/** 订阅筛选 chip 数据（按 id 过滤，避免同名订阅互相覆盖） */
interface SubChip {
  id: string;
  name: string;
}

/** 站点列表编辑对话框（强制代理/强制直连共用）。
 *  输入框用深色主题: 比弹窗底更深的蓝黑 + 浅色文字 + 紫色光标, 可读且不突兀。 */
@CustomDialog
struct NodeDeleteDialog {
  controller?: CustomDialogController;
  getNodeName: () => string = (): string => '';
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('删除节点').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text(`确定删除「${this.getNodeName()}」吗？该节点在订阅刷新后不会再出现。`)
        .fontSize(13).fontColor(Ui.textSecondary)
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1).backgroundColor(Ui.surfaceTranslucent).fontColor(Ui.textSecondary)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
          })
          .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
          .borderWidth(1).borderColor(Ui.glassEdge)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('删除')
          .layoutWeight(1).backgroundColor(Ui.error).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm();
          })
      }
      .width('100%')
    }
    .padding(22)
    .borderRadius(20)
    .backgroundColor(Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .shadow({ radius: 28, color: Ui.shadow, offsetY: 12 })
  }
}

@CustomDialog
struct SiteListDialog {
  controller?: CustomDialogController;
  title: string = '';
  description: string = '';
  placeholder: string = '';
  /** 打开时刻惰性读取当前已存列表（避免控制器构造期快照导致重开丢数据） */
  getInitial: () => string = () => '';
  onConfirm: (sites: string[]) => void = () => {};
  @State sitesText: string = '';

  aboutToAppear(): void {
    this.sitesText = this.getInitial();
  }

  build() {
    Column({ space: 14 }) {
      Text(this.title).fontSize(18).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text(this.description)
        .fontSize(12).fontColor(Ui.textTertiary)
      TextArea({ placeholder: this.placeholder, text: this.sitesText })
        .onChange((v: string) => { this.sitesText = v; })
        .height(150)
        .borderRadius(12)
        .backgroundColor(Ui.surfaceTranslucent)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
          colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
        })
        .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
        .fontColor(Ui.textPrimary)
        .placeholderColor(Ui.textTertiary)
        .caretColor(Ui.primary)
        .borderWidth(1)
        .borderColor(Ui.borderStrong)
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(Ui.surfaceTranslucent)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
          })
          .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
          .borderWidth(1)
          .borderColor(Ui.glassEdge)
          .fontColor(Ui.textSecondary)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('保存')
          .layoutWeight(1)
          .backgroundColor(Ui.primaryBlueFill)
          .fontColor(Color.White)
          .onClick(() => {
            const sites = this.sitesText.split(/\r?\n/)
              .map((s: string) => s.trim())
              .filter((s: string) => s.length > 0);
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm(sites);
          })
      }
      .width('100%')
    }
    .padding(24)
    .borderRadius(20)
    .backgroundColor(Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1)
    .borderColor(Ui.glassEdge)
    .shadow({ radius: 28, color: Ui.shadow, offsetY: 12 })
  }
}

@Entry
@Component
struct NodeSelectionPage {
  @State nodes: NodeRow[] = [];
  @State filterSubId: string = ''; // '' = 全部
  private listScroller: Scroller = new Scroller();
  @State subChips: SubChip[] = []; // 响应式订阅筛选列表（onPageShow 异步加载后刷新）
  @State selectedName: string = '';
  @State testingName: string = '';
  @State batchTesting: boolean = false;
  /**
   * 批次代次：每次开始/取消测速自增。旧批次的 worker 与在途回调发现代次不匹配
   * 就立即退出并丢弃结果，避免「页面退出后旧批次仍在写 UI / 占着测速通道」。
   */
  private batchGen: number = 0;
  /** 排序模式: default 订阅顺序 / auto 按持久化的最近测速结果 / manual 手动固定顺序。
   *  进页面时由 AppSettings.nodeSortMode + nodeSortSnapshot 恢复，测速完成后落盘。 */
  @State sortMode: string = NodeSortModes.DEFAULT;
  /** 最近一次测速快照（内存镜像，随设置持久化） */
  private sortSnapshot: NodeSortSnapshot | null = null;
  /** 长按删除节点目标 */
  @State deleteTargetName: string = '';
  private deleteTargetId: string = '';
  private deleteNodeDialog: CustomDialogController = new CustomDialogController({
    builder: NodeDeleteDialog({
      getNodeName: (): string => this.deleteTargetName,
      onConfirm: () => {
        this.doDeleteNode();
      }
    }),
    autoCancel: true
  });
  /** headless 测速内核: 未连接时预启动真实协议栈, 每页会话只尝试一次 */
  private testCoreTried: boolean = false;
  private testCoreOk: boolean = false;
  /** 本次会话选定的测速通道（批量开始前一次性确定，避免逐节点漂移） */
  private latencyChannel: string = CHANNEL_DIRECT;
  /** TestCore 明确启动失败后的直连结果只表示端口可达，绝不冒充代理延迟。 */
  private directReachableNames: Set<string> = new Set<string>();
  @State refreshing: boolean = false;
  @State isConnected: boolean = false;
  @State latencyTick: number = 0;
  /** 固定监听器实例，避免每次返回节点页都追加匿名监听，造成重复刷新和页面卡顿。 */
  private readonly latencyListener: () => void = (): void => {
    this.latencyTick = this.latencyTick + 1;
  };
  private latencyListenerBound: boolean = false;
  /** 页面切入时先完成首帧绘制，再启动设置/订阅加载，避免初始化与转场争抢 UI 线程。 */
  private pageActive: boolean = false;
  @State proxyMode: string = 'rule';
  /** 自动选点模式（'manual' 手动固定 / 'auto' 自动最优），进页面从持久化读取 */
  @State autoSelectMode: string = AutoSelectModes.MANUAL;
  private subs: SubscriptionService = new SubscriptionService();
  private settings: AppSettings = new AppSettings();
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  /** 强制代理网站 对话框 */
  private forceProxyDialog: CustomDialogController = new CustomDialogController({
    builder: SiteListDialog({
      title: '强制代理网站',
      description: '每行一个域名，这些站点将始终走代理（对齐 force_proxy_site_policy）',
      placeholder: 'example.com\nopenai.com',
      getInitial: (): string => this.settings.forceProxySites.join('\n'),
      onConfirm: (sites: string[]) => {
        this.settings.forceProxySites = sites;
        this.persistAndMaybeRestart('forceProxySites', `已保存 ${sites.length} 个强制代理站点`);
      }
    })
  });
  /** 强制直连网站 对话框 */
  private forceDirectDialog: CustomDialogController = new CustomDialogController({
    builder: SiteListDialog({
      title: '强制直连网站',
      description: '每行一个域名，这些站点将始终直连，不走代理',
      placeholder: 'example.cn\nbaidu.com',
      getInitial: (): string => this.settings.forceDirectSites.join('\n'),
      onConfirm: (sites: string[]) => {
        this.settings.forceDirectSites = sites;
        this.persistAndMaybeRestart('forceDirectSites', `已保存 ${sites.length} 个强制直连站点`);
      }
    })
  });
  /** 不走代理的应用(按包名) 对话框 */
  private bypassAppsDialog: CustomDialogController = new CustomDialogController({
    builder: SiteListDialog({
      title: '不走代理的应用',
      description: '每行一个应用包名，这些 App 的流量完全绕过 VPN 直连物理网络（不受加速影响）。抖音=com.ss.hm.ugc.aweme，微信=com.tencent.wechat',
      placeholder: 'com.ss.hm.ugc.aweme\ncom.tencent.wechat',
      getInitial: (): string => this.settings.excludedApps.join('\n'),
      onConfirm: (pkgs: string[]) => {
        this.settings.excludedApps = pkgs;
        this.persistAndMaybeRestart('excludedApps', `已保存 ${pkgs.length} 个免代理应用`);
      }
    })
  });

  /** 落盘后自动重启隧道(若已连接)。先 await save 再 restart, 确保重连读到最新配置。 */
  private persistAndMaybeRestart(reason: string, savedMsg: string): void {
    SettingsService.save(this.settings).then(async () => {
      const did = await this.orchestrator.restartIfConnected(reason);
      promptAction.showToast({ message: did ? savedMsg + '，正在自动重连…' : savedMsg + '，下次连接生效' });
    });
  }

  onPageShow(): void {
    this.pageActive = true;
    setTimeout(() => {
      if (this.pageActive) {
        this.bootstrap();
      }
    }, 32);
  }

  /** 离开节点页即回收测速内核（它是临时进程，不该在后台常驻） */
  onPageHide(): void {
    this.pageActive = false;
    // 立即取消未完成测速：作废批次 + 中断在途 HTTP（内核侧出站连接随之释放），
    // 避免旧批次继续占用测速通道。但**不**立刻回收 headless 测速内核 —— 改为
    // 宽限回收，让「来回切页面 / 连点测速」复用同一个内核，不再每次 stop→start。
    this.batchGen = this.batchGen + 1;
    this.batchTesting = false;
    this.testingName = '';
    this.orchestrator.api.cancelInflight();
    if (this.testCoreOk) {
      this.orchestrator.scheduleTestCoreRecycle(TEST_CORE_KEEP_ALIVE_MS);
    }
    if (this.latencyListenerBound) {
      LatencyController.removeListener(this.latencyListener);
      this.latencyListenerBound = false;
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    // 重新进入节点页：取消离开时挂起的「宽限回收测速内核」，
    // 让本次测速继续复用同一内核（否则定时器会在页面打开期间把内核停掉）。
    this.orchestrator.cancelTestCoreRecycle();
    await SettingsService.init(ctx);
    const apiSecret = await SettingsService.getApiSecret();
    this.orchestrator.api.setEndpoint(9090, apiSecret);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    this.proxyMode = this.settings.proxyMode === 'global' ? 'global' : 'rule';
    this.autoSelectMode = AutoSelectModes.normalize(this.settings.autoSelectMode);
    this.restoreSortState();
    this.isConnected = this.orchestrator.state === ConnState.CONNECTED;
    if (this.isConnected) {
      // 真实 VPN 已接管扩展进程, headless 测速内核标记复位
      this.testCoreTried = false;
      this.testCoreOk = false;
    }
    this.selectedName = this.settings.preferredNodeId.length > 0 && this.subs.findNode(this.settings.preferredNodeId) !== null
      ? this.subs.findNode(this.settings.preferredNodeId)!.name
      : (this.subs.nodes.length > 0 ? this.subs.nodes[0].name : '');
    // 响应式更新订阅筛选 chips（异步 init 完成后必须触发渲染）
    const chips: SubChip[] = [];
    for (const s of this.subs.subscriptions) {
      chips.push({ id: s.id, name: s.name });
    }
    this.subChips = chips;
    // 上次选中的筛选订阅已删除时回到全部
    if (this.filterSubId.length > 0 && !this.subs.subscriptions.some((s) => s.id === this.filterSubId)) {
      this.filterSubId = '';
    }
    // 进入页面自动定位到当前节点所属订阅（"全部"是初始态而非用户主动选择时）：
    // 修复"每次进来都停在全部列表、要手动找节点"的体验问题。
    if (this.filterSubId.length === 0 && this.settings.preferredNodeId.length > 0) {
      const cur = this.subs.findNode(this.settings.preferredNodeId);
      if (cur !== null && cur.subscriptionId.length > 0 && cur.subscriptionId !== 'direct'
        && this.subs.subscriptions.some((s) => s.id === cur.subscriptionId)) {
        this.filterSubId = cur.subscriptionId;
      }
    }
    this.rebuildRows();
    // 定位到当前选中节点行（等 nodes 状态驱动的 List 完成构建再滚动）
    const selectedIndex = this.nodes.findIndex((r) => r.node.name === this.selectedName);
    if (selectedIndex > 0) {
      setTimeout(() => {
        this.listScroller.scrollToIndex(selectedIndex, true);
      }, 350);
    }
    if (!this.latencyListenerBound) {
      LatencyController.addListener(this.latencyListener);
      this.latencyListenerBound = true;
    }
  }

  /**
   * 由持久化测速快照派生单个节点的综合评分与状态（纯展示，不改任何持久化）。
   * 成功率沿用 NodeLatencyRecord.recentSuccessRate() 语义；评分复用 SmartSelector.scoreOf。
   * 「冷却中」= 近期已失败且连续失败次数达到「故障切换阈值」（该节点会被自动选点视为失效）。
   */
  private statusFor(name: string): NodeStatusView {
    const st = new NodeStatusView();
    const snap = this.sortSnapshot;
    if (snap === null) {
      return st;
    }
    const rec = snap.recordFor(name);
    if (rec === null || rec.latency === -2) {
      return st;
    }
    st.hasData = true;
    st.failCount = rec.failCount;
    const rate = rec.recentSuccessRate();
    st.rateLabel = rate < 0 ? '--' : `${Math.round(rate * 100)}%`;
    const cand = NodeCandidate.fromStats(name, rec.latency, rec.failCount, rec.lastOk, 0, 0);
    st.score = Math.round(scoreOf(cand, Date.now()));
    return st;
  }

  private rebuildRows(): void {
    const rows: NodeRow[] = [];
    const activeNames: string[] = [];
    for (const n of this.subs.nodes) {
      activeNames.push(n.name);
      if (this.filterSubId.length > 0 && n.subscriptionId !== this.filterSubId) {
        continue;
      }
      const row: NodeRow = {
        node: n,
        countryCode: NodeCountryPolicy.detect(n.name).code,
        status: this.statusFor(n.name)
      };
      rows.push(row);
    }
    LatencyController.retainOnly(activeNames);
    // 排序：按持久化的测速快照恢复顺序（auto/manual），无数据则保持订阅原始顺序
    if (this.sortMode !== NodeSortModes.DEFAULT) {
      const snap = this.sortSnapshot;
      if (snap !== null) {
        const names: string[] = [];
        for (const r of rows) {
          names.push(r.node.name);
        }
        const order = snap.orderedNames(names);
        if (order.length > 0) {
          const byName = new Map<string, NodeRow>();
          for (const r of rows) {
            byName.set(r.node.name, r);
          }
          const reordered: NodeRow[] = [];
          for (const name of order) {
            const r = byName.get(name);
            if (r !== undefined) {
              reordered.push(r);
            }
          }
          this.nodes = reordered;
          return;
        }
      }
    }
    this.nodes = rows;
  }

  /**
   * 页面初始化时恢复排序状态:
   * 从设置里反序列化最近一次测速快照 + 排序模式，并把快照中的延迟回填到
   * LatencyController（否则重启后列表顺序对了但延迟数字仍显示"未测试"）。
   * 快照损坏 / 无数据时回退 default（订阅原始顺序）。
   */
  private restoreSortState(): void {
    const snap = NodeSortSnapshot.fromJsonText(this.settings.nodeSortSnapshot);
    const mode = NodeSortModes.normalize(this.settings.nodeSortMode);
    if (snap === null || (mode === NodeSortModes.AUTO && !snap.hasLatencyData())
      || (mode === NodeSortModes.MANUAL && snap.order.length === 0)) {
      this.sortSnapshot = snap;
      this.sortMode = NodeSortModes.DEFAULT;
      return;
    }
    this.sortSnapshot = snap;
    this.sortMode = mode;
    for (const rec of snap.records) {
      if (rec.latency !== -2) {
        LatencyController.set(rec.name, rec.latency);
      }
    }
  }

  /** 落盘排序模式 + 测速快照（随 AppSettings 持久化，无需重连隧道） */
  private async persistSortState(): Promise<void> {
    this.settings.nodeSortMode = this.sortMode;
    this.settings.nodeSortSnapshot = this.sortSnapshot === null ? '' : this.sortSnapshot.toJsonText();
    await SettingsService.save(this.settings);
  }

  /** 排序模式中文说明（用于 toast） */
  private sortModeLabel(mode: string): string {
    if (mode === NodeSortModes.AUTO) {
      return '自动排序（按测速结果）';
    }
    if (mode === NodeSortModes.MANUAL) {
      return '手动固定顺序';
    }
    return '默认顺序';
  }

  /** 用户切换排序模式（点击排序按钮）: 循环 default → auto → manual → default 并持久化 */
  private cycleSortMode(): void {
    const next = this.sortMode === NodeSortModes.DEFAULT ? NodeSortModes.AUTO
      : (this.sortMode === NodeSortModes.AUTO ? NodeSortModes.MANUAL : NodeSortModes.DEFAULT);
    this.sortMode = next;
    // 切到 manual 时把当前可见顺序固化为固定顺序
    if (next === NodeSortModes.MANUAL) {
      const order: string[] = [];
      for (const r of this.nodes) {
        order.push(r.node.name);
      }
      const snap = this.sortSnapshot === null ? new NodeSortSnapshot() : this.sortSnapshot;
      snap.mode = NodeSortModes.MANUAL;
      snap.order = order;
      this.sortSnapshot = snap;
    } else if (this.sortSnapshot !== null) {
      this.sortSnapshot.mode = next;
    }
    this.rebuildRows();
    this.persistSortState();
    promptAction.showToast({ message: `排序方式：${this.sortModeLabel(next)}` });
  }

  /** 刷新: 全部订阅重新拉取并重建节点列表(对齐原版顶栏刷新图标职责) */
  private async refreshNodes(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    try {
      let ok = 0;
      let total = 0;
      for (const s of this.subs.subscriptions) {
        const r = await this.subs.refreshSubscription(s.id);
        if (r.status === SubscriptionRefreshStatus.OK) {
          ok = ok + 1;
          total = total + r.nodeCount;
        }
      }
      this.rebuildRows();
      promptAction.showToast({ message: ok > 0 ? `刷新完成，共 ${total} 个节点` : '刷新失败，请检查网络' });
    } catch (e) {
      promptAction.showToast({ message: '刷新失败，请检查网络' });
    }
    this.refreshing = false;
  }

  private async testOne(node: ProxyNode): Promise<void> {
    if (this.batchTesting || this.testingName.length > 0) {
      return;
    }
    const generation = this.batchGen + 1;
    this.batchGen = generation;
    this.testingName = node.name;
    await this.prepareLatencyChannel();
    if (this.batchGen !== generation) {
      return;
    }
    const delay = await this.testNodeDelay(node, SINGLE_NODE_TIMEOUT_MS);
    if (this.batchGen !== generation) {
      return;
    }
    if (this.latencyChannel === CHANNEL_DIRECT && delay >= 0) {
      this.directReachableNames.add(node.name);
      LatencyController.set(node.name, -2);
    } else if (delay !== -2) { // -2 = 协议不支持离线测试, 保持"未测试"态
      this.directReachableNames.delete(node.name);
      LatencyController.set(node.name, delay);
    }
    this.testingName = '';
  }

  /**
   * 一次性确定本次测速走哪条通道。
   *
   * 原实现把「懒加载测速内核」放在每个 worker 内部：第一个 worker 置
   * testCoreTried=true 后去 await ensureTestCore（DoH + 拉起内核，秒级），
   * 与此同时其余 worker 看到 testCoreOk 仍为 false，就各自退化成
   * DirectLatencyTester 的 TCP/QUIC 探测 —— 结果是同一批里「部分节点走真实
   * 协议栈、部分走裸 TCP 握手」，方法学漂移会让延迟数字不可比（可信度问题），
   * 还叠加了隐藏串行等待。现在改为批量开始前只判一次。
   *
   * 连通性也在这里用权威判据复判：ensureTestCore 内部同样会拒绝在真实隧道
   * 存活时启动（否则第一步 stopVpnExtensionAbility 会把用户正在用的 VPN 停掉）。
   */
  private async prepareLatencyChannel(): Promise<void> {
    this.isConnected = await this.orchestrator.isAuthoritativelyConnected();
    if (this.isConnected) {
      this.latencyChannel = CHANNEL_KERNEL;
      return;
    }
    if (!this.testCoreTried) {
      this.testCoreTried = true;
      this.testCoreOk = await this.orchestrator.ensureTestCore(this.subs, this.settings);
    }
    this.latencyChannel = this.testCoreOk ? CHANNEL_KERNEL : CHANNEL_DIRECT;
  }

  /**
   * 测速策略（回应"没启动 VPN 测通、启动后却超时"的误报）：
   * 未连接时先懒加载一个 headless 内核（不建 TUN、不请求 VPN 授权），
   * 走 /proxies/{name}/delay 真实协议测速 —— 与连上后同一套判定；
   * 内核拉不起来时才回退 DirectLatencyTester 的 TCP/QUIC 探测。
   * 已连接时直接走 Clash API。
   */

  /**
   * 使用当前轮共享 URL 测速。主地址首次失败时仅由一个调用切换并测试备用地址，
   * 其他并发 worker 随后直接复用已缓存的备用地址，禁止逐节点重复主备双测。
   */
  private async testNodeDelay(node: ProxyNode, timeoutMs: number): Promise<number> {
    if (!(this.isConnected || this.testCoreOk)) {
      // TestCore 明确启动失败时才降级。此结果只表示端口可达性，调用方不得
      // 将它写成普通代理延迟；底层探测仍严格服从调用方的毫秒超时。
      return DirectLatencyTester.testNode(node, timeoutMs);
    }
    const urls: string[] = [];
    const primary = this.settings.testLatencyUrl.trim();
    if (primary.length > 0) {
      urls.push(primary);
    }
    for (const fallback of LATENCY_FALLBACK_URLS) {
      if (urls.indexOf(fallback) < 0) {
        urls.push(fallback);
      }
    }
    // 所有 URL 尝试共享一个单节点总预算，回退不会把 timeout 成倍放大。
    const deadline = Date.now() + timeoutMs;
    for (let index = 0; index < urls.length; index++) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        return -1;
      }
      const attemptsLeft = urls.length - index;
      const attemptBudget = attemptsLeft > 1
        ? Math.max(250, Math.floor(remaining / attemptsLeft)) : remaining;
      const delay = await this.orchestrator.api.testLatency(node.name, urls[index], attemptBudget);
      if (delay >= 0) {
        return delay;
      }
      AppLogger.warn(TAG, `latency URL failed: index=${index + 1}/${urls.length}`);
    }
    return -1;
  }

  /** 长按删除单个节点 */
  private async doDeleteNode(): Promise<void> {
    if (this.deleteTargetId.length === 0) {
      return;
    }
    const removed = this.subs.findNode(this.deleteTargetId);
    const wasSelected = this.settings.preferredNodeId === this.deleteTargetId;
    const ok = await this.subs.removeNode(this.deleteTargetId);
    this.deleteTargetId = '';
    if (!ok) {
      promptAction.showToast({ message: '删除失败，请重试' });
      return;
    }
    if (wasSelected) {
      this.settings.preferredNodeId = '';
      await SettingsService.save(this.settings);
      this.selectedName = this.subs.nodes.length > 0 ? this.subs.nodes[0].name : '';
    }
    this.rebuildRows();
    promptAction.showToast({ message: removed !== null ? `已删除「${removed.name}」` : '已删除' });
  }

  /**
   * 批量测速。
   *
   * 提速点（相对旧实现，逐条对应代码路径）：
   *  1) 通道预热：批量开始前一次性判定「内核 / 直连探测」。旧实现把懒加载放在
   *     每个 worker 里，第一个 worker 去 await 拉起内核（DoH + 内核就绪，秒级）
   *     期间，其余 worker 各自退化成裸 TCP/QUIC 探测 —— 既让同一批结果方法学
   *     不一致，又白白混进一段串行等待。
   *  2) LPT 调度：把「上次失败 / 有失败历史」的节点排到队首，让最慢的长尾超时
   *     尽早并行开始（longest-processing-time-first），整批 makespan 不再被最后
   *     才取到的死节点拖住。
   *  3) 有界并发 8 路：12 路会让同一内核的出站握手互相挤占、把延迟打高（那是
   *     牺牲可信度换来的假提速）。
   *  4) 单节点超时 5000→4000ms：只对确定打不通的节点提前失败。
   *  5) 结果通知合并：LatencyController 从「每条结果一次整表重排」压到每 200ms
   *     一次，UI 线程不再被 125 次重排占满。
   */
  private async testAll(): Promise<void> {
    if (this.batchTesting) {
      return;
    }
    const generation = this.batchGen + 1;
    this.batchGen = generation;
    this.batchTesting = true;
    const batchStartedAt = Date.now();
    // 1) 通道预热（一次，放在所有 worker 之外）
    await this.prepareLatencyChannel();
    if (this.batchGen !== generation || !this.batchTesting) {
      return;
    }
    // 2) 队列排序：长尾优先
    const rows = this.buildLatencyQueue();
    const list = rows.map((r) => r.node);
    AppLogger.info(TAG, `batch latency start: nodes=${list.length} lanes=${BATCH_LANES} `
      + `channel=${this.latencyChannel}`);
    let cursor = 0;
    // 收集本批测速结果（含 -2 未测试）用于构建持久化快照
    const collected: NodeLatencyRecord[] = [];
    for (const n of list) {
      const rec = new NodeLatencyRecord();
      rec.name = n.name;
      rec.latency = -2;
      collected.push(rec);
    }
    const workers: Promise<void>[] = [];
    const lanes = Math.min(BATCH_LANES, list.length);
    for (let w = 0; w < lanes; w++) {
      workers.push((async (): Promise<void> => {
        for (;;) {
          if (!this.batchTesting || this.batchGen !== generation) {
            return; // 批次被取消或已被新批次取代
          }
          const i = cursor;
          cursor = cursor + 1;
          if (i >= list.length) {
            return;
          }
          const delay = await this.testNodeDelay(list[i], BATCH_NODE_TIMEOUT_MS);
          // 请求返回后再次检查代次，迟到响应不得覆盖新批次。
          if (!this.batchTesting || this.batchGen !== generation) {
            return;
          }
          if (this.latencyChannel === CHANNEL_DIRECT && delay >= 0) {
            this.directReachableNames.add(list[i].name);
            LatencyController.set(list[i].name, -2);
            collected[i].latency = -2;
          } else {
            this.directReachableNames.delete(list[i].name);
            if (delay !== -2) {
              LatencyController.set(list[i].name, delay);
            }
            collected[i].latency = delay;
          }
        }
      })());
    }
    await Promise.all(workers);
    // 快速批测只执行一轮。旧逻辑会把首轮所有失败节点再次完整测试，
    // 在大量不可用节点时几乎把整轮耗时翻倍。需要确认的节点仍可点击单独测速，
    // 单节点路径保留 5 秒宽松超时。
    // 合并窗口内的最后一批结果立即上屏，别让用户多等 200ms
    LatencyController.flushNow();
    const cancelled = !this.batchTesting || this.batchGen !== generation;
    this.batchTesting = false;
    this.testingName = '';
    let okCount = 0;
    let failedCount = 0;
    let untestedCount = 0;
    for (const rec of collected) {
      if (rec.latency === -2) {
        untestedCount = untestedCount + 1;
      } else if (rec.latency < 0) {
        failedCount = failedCount + 1;
      } else {
        okCount = okCount + 1;
      }
    }
    AppLogger.info(TAG, `batch latency done: ok=${okCount} failed=${failedCount} `
      + `untested=${untestedCount} lanes=${lanes} channel=${this.latencyChannel} `
      + `elapsed=${Date.now() - batchStartedAt}ms`);
    if (cancelled) {
      return; // 用户中途取消: 不覆盖已持久化的排序结果
    }
    // 测速完成 → 构建新快照整体覆盖旧顺序（延迟升序，失败/未测沉底）并持久化
    this.sortSnapshot = NodeSortSnapshot.buildAuto(Date.now(), collected, this.sortSnapshot);
    this.sortMode = NodeSortModes.AUTO;
    this.rebuildRows();
    await this.persistSortState();
    promptAction.showToast({ message: '测速完成，已按延迟排序并保存' });
  }

  /**
   * 队列排序：LPT（最长预计耗时优先）。
   * 上次失败/超时(3) → 有失败历史(2) → 未测/不支持离线(1) → 上次成功(0)。
   * 稳定性由 ArkTS Array.sort 保证（权重相同的保持原相对顺序）。
   */
  private buildLatencyQueue(): NodeRow[] {
    const rows: NodeRow[] = this.nodes.slice();
    const snapshot = this.sortSnapshot;
    if (snapshot === null) {
      return rows;
    }
    const weight = (row: NodeRow): number => {
      const rec = snapshot.recordFor(row.node.name);
      if (rec === null || rec.latency === -2) {
        return 1;
      }
      if (rec.latency < 0) {
        return 3;
      }
      if (rec.failCount > 0) {
        return 2;
      }
      return 0;
    };
    rows.sort((a: NodeRow, b: NodeRow): number => weight(b) - weight(a));
    return rows;
  }

  private async selectNode(node: ProxyNode): Promise<void> {
    this.settings.preferredNodeId = node.id;
    this.selectedName = node.name;
    await SettingsService.save(this.settings);
    if (this.isConnected) {
      const ok = await this.orchestrator.api.selectNode(node.name);
      if (!ok) {
        promptAction.showToast({ message: '切换节点失败，请查看诊断' });
      }
    }
    promptAction.showToast({ message: `已选择 ${NodeDisplay.compact(NodeDisplay.withoutLeadingFlag(node.name))}` });
  }

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .linearGradient({ angle: 135, colors: Ui.backdropColors })
        // 背景延伸到状态栏/底部导航条之下, 消除底部白条
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // ── 顶栏（对齐原版: 返回 + 当前节点 + 刷新/闪电图标组） ──
        Row() {
          Text('←')
            .fontSize(22).fontColor(Ui.textPrimary)
            .onClick(() => router.back())
          Row({ space: 7 }) {
            CountryFlagIcon({
              nodeName: this.selectedName.length > 0 ? this.selectedName : 'UN',
              iconSize: 22
            })
            Text(this.selectedName.length > 0
              ? NodeDisplay.compact(NodeDisplay.withoutLeadingFlag(this.selectedName))
              : '选择节点')
              .fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(Ui.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .layoutWeight(1)
          .constraintSize({ minWidth: 0 })
          .margin({ left: 12, right: 12 })
          // 刷新(重载节点/订阅) + 排序方式 + 闪电(测速) 图标组
          Row({ space: 14 }) {
            Text(this.refreshing ? '◌' : '⟳')
              .fontSize(22)
              .fontColor(this.refreshing ? Ui.primary : Ui.textPrimary)
              .onClick(() => this.refreshNodes())
            Text(this.sortMode === NodeSortModes.AUTO ? '⇅'
              : (this.sortMode === NodeSortModes.MANUAL ? '🔒' : '↕'))
              .fontSize(20)
              .fontColor(this.sortMode === NodeSortModes.DEFAULT ? Ui.textPrimary : Ui.primary)
              .onClick(() => this.cycleSortMode())
            Text(this.batchTesting ? '⏳' : '⚡')
              .fontSize(21)
              .fontColor(this.batchTesting ? Ui.primary : Ui.textPrimary)
              .onClick(() => {
                if (this.batchTesting) {
                  this.batchGen = this.batchGen + 1;
                  this.batchTesting = false;
                  this.orchestrator.api.cancelInflight();
                } else {
                  this.testAll();
                }
              })
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 10, bottom: 6 })

        // ── 代理设置主卡片（对齐原版: 代理模式标题行 + 智能/全局分段控件） ──
        Column({ space: 12 }) {
          // 标题行: 分流图标 + 代理模式 + 说明文字
          Row({ space: 7 }) {
            Text('⑂').fontSize(17).fontColor(Ui.textSecondary)
            Text('代理模式')
              .fontSize(15).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
            Blank()
          }
          .width('100%')
          Text('国内服务直接连接，海外及未知流量走代理')
            .fontSize(11).fontColor(Ui.textTertiary)
            .width('100%')
            .margin({ top: -8 })
          // 分段控件: 智能(规则) / 全局
          Row() {
            this.ModeChip('rule', '✦', '智能')
            this.ModeChip('global', '🌐', '全局')
          }
          .width('100%')
          .padding(4)
          .borderRadius(14)
          .backgroundColor(Ui.surfaceTranslucent)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
          })
          .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
          .borderWidth(1)
          .borderColor(Ui.glassEdge)
        }
        .width('100%')
        .padding(16)
        .borderRadius(20)
        .backgroundColor(Ui.surfaceTranslucent)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
          colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
        })
        .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
        .borderWidth(1)
        .borderColor(Ui.glassEdge)
        .shadow({ radius: 24, color: Ui.shadow, offsetY: 10 })
        .margin({ top: 8 })

        // ── 底部快捷操作（对齐原版: 强制代理网站 / 强制直连网站） ──
        Row({ space: 12 }) {
          Row({ space: 7 }) {
            Text('🔗').fontSize(14)
            Text('强制代理网站')
              .fontSize(13).fontWeight(FontWeight.Medium).fontColor(Ui.textBlue)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .padding({ top: 9, bottom: 9 })
          .borderRadius(13)
          .backgroundColor(Ui.surfaceTranslucent)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
          })
          .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
          .borderWidth(1)
          .borderColor(Ui.glassEdge)
          .onClick(() => this.forceProxyDialog.open())

          Row({ space: 7 }) {
            Text('⛓').fontSize(14)
            Text('强制直连网站')
              .fontSize(13).fontWeight(FontWeight.Medium).fontColor(Ui.textBlue)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .padding({ top: 9, bottom: 9 })
          .borderRadius(13)
          .backgroundColor(Ui.surfaceTranslucent)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
          })
          .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
          .borderWidth(1)
          .borderColor(Ui.glassEdge)
          .onClick(() => this.forceDirectDialog.open())
        }
        .width('100%')
        // 与上方代理卡片拉开间距, 避免视觉重叠
        .margin({ top: 18 })

        // ── 不走代理的应用(按包名排除, VpnConfig.blockedApplications) ──
        Row({ space: 7 }) {
          Text('📱').fontSize(14)
          Text('不走代理的应用')
            .fontSize(13).fontWeight(FontWeight.Medium).fontColor(Ui.accent)
          if (this.settings.excludedApps.length > 0) {
            Text(`${this.settings.excludedApps.length}`)
              .fontSize(11).fontColor(Ui.textPrimary)
              .padding({ left: 7, right: 7, top: 1, bottom: 1 })
              .borderRadius(9)
              .backgroundColor(Ui.accent)
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 9, bottom: 9 })
        .borderRadius(13)
        .backgroundColor(Ui.surfaceTranslucent)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
          colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
        })
        .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
        .borderWidth(1)
        .borderColor(Ui.glassEdge)
        .margin({ top: 10 })
        .onClick(() => this.bypassAppsDialog.open())

        // ── 订阅筛选 chips ──
        if (this.subChips.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              Text('全部')
                .fontSize(13)
                .fontColor(this.filterSubId.length === 0 ? Ui.textPrimary : Ui.textSecondary)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(16)
                .backgroundColor(this.filterSubId.length === 0 ? Ui.selectedBackground : Ui.surfaceTranslucent)
                .borderWidth(1)
                .borderColor(this.filterSubId.length === 0 ? Ui.primary : Ui.border)
                .onClick(() => {
                  this.filterSubId = '';
                  this.rebuildRows();
                })
              ForEach(this.subChips, (chip: SubChip) => {
                Text(chip.name)
                  .fontSize(13)
                  .fontColor(this.filterSubId === chip.id ? Ui.textPrimary : Ui.textSecondary)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(16)
                  .backgroundColor(this.filterSubId === chip.id ? Ui.selectedBackground : Ui.surfaceTranslucent)
                  .borderWidth(1)
                  .borderColor(this.filterSubId === chip.id ? Ui.primary : Ui.border)
                  .onClick(() => {
                    this.filterSubId = chip.id;
                    this.rebuildRows();
                  })
              }, (chip: SubChip) => chip.id + '#' + chip.name)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          // 与上方快捷按钮拉开间距
          .padding({ left: 18, right: 18, top: 18, bottom: 6 })
        }

        // ── 选点模式说明：明确区分「手动固定」与「自动排序」，澄清自动切换不会覆盖手动选择 ──
        Row({ space: 6 }) {
          Text(this.autoSelectMode === AutoSelectModes.AUTO ? '⚡' : '🔒')
            .fontSize(12)
            .fontColor(this.autoSelectMode === AutoSelectModes.AUTO ? Ui.warning : Ui.textSecondary)
          Text(this.autoSelectMode === AutoSelectModes.AUTO
            ? $r('app.string.node_mode_auto_banner')
            : $r('app.string.node_mode_manual_banner'))
            .fontSize(11)
            .fontColor(Ui.textSecondary)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(12)
        .backgroundColor(Ui.surfaceTranslucent)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
          colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
        })
        .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
        .borderWidth(1)
        .borderColor(Ui.glassEdge)
        .margin({ left: 18, right: 18, top: 10 })

        // ── 节点列表 ──
        // 说明文案只保留上方那条横幅（模式 + 长按删除提示），
        // 此前这里还有一行「排序：自动排序（按测速结果）」与横幅重复，已移除。
        if (this.nodes.length === 0) {
          Column({ space: 12 }) {
            Text('🖧').fontSize(46).fontColor(Ui.textTertiary)
            Text('暂无可用节点').fontSize(15).fontColor(Ui.textSecondary)
          }
          .width('100%')
          .margin({ top: 120 })
        } else {
          List({ space: 7, scroller: this.listScroller }) {
            ForEach(this.nodes, (row: NodeRow) => {
              ListItem() {
                this.NodeCard(row)
              }
              .gesture(LongPressGesture().onAction(() => {
                this.deleteTargetId = row.node.id;
                this.deleteTargetName = row.node.name;
                this.deleteNodeDialog.open();
              }))
            }, (row: NodeRow) => row.node.id + '#' + this.latencyTick.toString() + '#' + this.testingName)
          }
          .layoutWeight(1)
          .padding({ left: 18, right: 18, top: 8, bottom: 20 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
  }

  /** 分段控件选项卡（智能=规则 / 全局; 对应 upstream proxyMode, 运行时经 Clash API 生效） */
  @Builder
  ModeChip(mode: string, icon: string, label: string) {
    Row({ space: 6 }) {
      Text(icon)
        .fontSize(14)
        .fontColor(this.proxyMode === mode ? Ui.textViolet : Ui.textSecondary)
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.proxyMode === mode ? Ui.textViolet : Ui.textSecondary)
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .padding({ top: 9, bottom: 9 })
    .borderRadius(11)
    .backgroundColor(this.proxyMode === mode ? Ui.selectedBackground : Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1)
    .borderColor(this.proxyMode === mode ? Ui.primary : Ui.glassEdge)
    .shadow(this.proxyMode === mode ? { radius: 12, color: Ui.shadow, offsetY: 4 } : { radius: 0, color: Color.Transparent })
    .onClick(() => {
      if (this.proxyMode === mode) {
        return;
      }
      this.proxyMode = mode;
      this.settings.proxyMode = mode;
      // 模式写在 YAML 里, 需重建隧道生效: 落盘后自动断开重连(未连接则下次连接生效)
      const label = mode === 'global' ? '全局模式' : '智能(规则)模式';
      SettingsService.save(this.settings).then(async () => {
        const did = await this.orchestrator.restartIfConnected('proxyMode=' + mode);
        promptAction.showToast({ message: did ? `已切换${label}，正在自动重连…` : `已切换${label}，下次连接生效` });
      });
    })
  }
  /** 协议类型徽标: vless/vmess/trojan/ss/ssr/hysteria2，REALITY 节点追加 ·REALITY */
  @Builder
  ProtocolBadge(node: ProxyNode) {
    Row({ space: 5 }) {
      Text(NodeProtocolPolicy.fromNode(node).display())
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(NodeProtocolPolicy.isRealityNode(node) ? Ui.textViolet : Ui.textSecondary)
        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
        .borderRadius(6)
        .backgroundColor(Ui.surfaceTranslucent)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
          colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
        })
        .borderWidth(1)
        .borderColor(NodeProtocolPolicy.isRealityNode(node) ? Ui.primary : Ui.glassEdge)
    }
  }

  /** 通用小徽标 */
  @Builder
  Badge(text: ResourceStr, color: ResourceColor) {
    Text(text)
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontColor(color)
      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
      .borderRadius(6)
      .backgroundColor(Ui.surfaceTranslucent)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
      })
      .borderWidth(1)
      .borderColor(Ui.glassEdge)
  }

  /**
   * 节点状态徽标（来自持久化测速快照）。
   *
   * 只展示对用户可操作的状态：未测速 / 连续失败次数 / 成功率。数字「综合评分」
   * 不再展示 —— 它是 SmartSelector 内部用于自动选点与故障切换排序的代价
   * （ms 等价值，越小越好），对用户没有直接可操作性，显示反而造成困惑；
   * 评分计算保留，供将来开启自动选点时使用。
   *
   * 「冷却中」徽标已移除：冷却只影响 SmartSelector 内部选点权重（保留不动），
   * 对用户没有可操作动作，展示它只会造成「节点坏了」的误导。
   */
  @Builder
  NodeStatusBadge(st: NodeStatusView) {
    Row({ space: 5 }) {
      if (!st.hasData) {
        this.Badge($r('app.string.node_badge_untested'), Ui.textTertiary)
      } else {
        if (st.failCount > 0) {
          this.Badge($r('app.string.node_badge_failed_count', st.failCount), Ui.warning)
        } else {
          this.Badge($r('app.string.node_badge_success_rate', st.rateLabel), Ui.success)
        }
      }
    }
  }

  @Builder
  NodeCard(row: NodeRow) {
    Row() {
      Row({ space: 12 }) {
        CountryFlagIcon({ nodeName: row.node.name, iconSize: 26 })
        Column({ space: 3 }) {
          Text(NodeDisplay.compact(NodeDisplay.withoutLeadingFlag(row.node.name)))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(row.node.name === this.selectedName ? Ui.primary : Ui.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Row({ space: 5 }) {
            this.ProtocolBadge(row.node)
            this.NodeStatusBadge(row.status)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .onClick(() => this.selectNode(row.node))

      Text(this.testingName === row.node.name ? '…'
        : (this.directReachableNames.has(row.node.name) ? '端口可达'
          : LatencyStyle.text(LatencyController.latencyFor(row.node.name))))
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.directReachableNames.has(row.node.name)
          ? Ui.textSecondary : LatencyStyle.color(LatencyController.latencyFor(row.node.name)))
        .padding({ left: 8, right: 8 })
        .onClick(() => this.testOne(row.node))

      Text('✓')
        .fontSize(20)
        .fontColor(Ui.primary)
        .width(24)
        .textAlign(TextAlign.Center)
        .opacity(row.node.name === this.selectedName ? 1 : 0)
    }
    .width('100%')
    .padding({ left: 14, right: 6, top: 7, bottom: 7 })
    .borderRadius(17)
    .backgroundColor(row.node.name === this.selectedName ? Ui.surfaceStrong : Ui.surfaceTranslucent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: Ui.glassBlurRadius, saturation: Ui.glassSaturationSoft, brightness: Ui.glassBrightnessSoft })
    .borderWidth(1)
    .borderColor(row.node.name === this.selectedName ? Ui.primary : Ui.glassEdge)
  }

  pageTransition() {
    // 仅做短促淡入淡出。移除整页位移动画，减少玻璃模糊层在每一帧的重采样开销。
    PageTransitionEnter({ duration: 170, curve: Curve.EaseOut })
      .opacity(0.88)
    PageTransitionExit({ duration: 120, curve: Curve.EaseIn })
      .opacity(0.94)
  }
}
