/**
 * 节点选择页 — 对齐 upstream SsrvpnNodeSelectionPage + _NodeSelectionCard
 * 顶栏(返回/标题/测全部) + 订阅筛选 chips + 节点卡列表（旗帜/名称/延迟按钮/选中勾）。
 */
import { router, promptAction } from '@kit.ArkUI';
import { Ui, LatencyStyle, NodeDisplay } from '../theme/UiTokens';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { Subscription, SubscriptionRefreshStatus } from '../commons/models/Subscription';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings } from '../commons/models/AppSettings';
import { ProxyNode } from '../commons/models/ProxyNode';
import { LatencyController } from '../commons/services/LatencyController';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { DirectLatencyTester } from '../commons/services/DirectLatencyTester';
import { NodeCountryPolicy } from '../commons/services/PublicIpService';
import { CountryFlagIcon } from '../widgets/CountryFlagIcon';

const TAG = 'NodeSelectionPage';

interface NodeRow {
  node: ProxyNode;
  countryCode: string;
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
          .layoutWeight(1).backgroundColor(Ui.surface).fontColor(Ui.textSecondary)
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
    .backgroundColor('#F0242641')
    .borderWidth(1)
    .borderColor(Ui.border)
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
        .backgroundColor('#101426')
        .fontColor('#F5F7FF')
        .placeholderColor('#6E7894')
        .caretColor('#8A84FF')
        .borderWidth(1)
        .borderColor('#3A4066')
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(Ui.surface)
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
    .backgroundColor('#E6242641')
    .borderWidth(1)
    .borderColor(Ui.border)
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
  /** 批量测速完成后按延迟升序重排列表 */
  @State sortByLatency: boolean = false;
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
  @State refreshing: boolean = false;
  @State isConnected: boolean = false;
  @State latencyTick: number = 0;
  @State proxyMode: string = 'rule';
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
    this.bootstrap();
  }

  /** 离开节点页即回收测速内核（它是临时进程，不该在后台常驻） */
  onPageHide(): void {
    if (this.testCoreOk || this.testCoreTried) {
      this.testCoreOk = false;
      this.testCoreTried = false;
      this.orchestrator.stopTestCore();
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await SettingsService.init(ctx);
    const apiSecret = await SettingsService.getApiSecret();
    this.orchestrator.api.setEndpoint(9090, apiSecret);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    this.proxyMode = this.settings.proxyMode === 'global' ? 'global' : 'rule';
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
    LatencyController.addListener(() => {
      this.latencyTick = this.latencyTick + 1;
    });
  }

  private rebuildRows(): void {
    const rows: NodeRow[] = [];
    for (const n of this.subs.nodes) {
      if (this.filterSubId.length > 0 && n.subscriptionId !== this.filterSubId) {
        continue;
      }
      const row: NodeRow = {
        node: n,
        countryCode: NodeCountryPolicy.detect(n.name).code
      };
      rows.push(row);
    }
    if (this.sortByLatency) {
      // 批量测速完成后: 已测成功升序 → 未测 → 失败沉底
      rows.sort((a: NodeRow, b: NodeRow): number => {
        const la = LatencyController.latencyFor(a.node.name);
        const lb = LatencyController.latencyFor(b.node.name);
        const ra = this.latencyRank(la);
        const rb = this.latencyRank(lb);
        if (ra !== rb) {
          return ra - rb;
        }
        if (ra === 0 && la !== null && lb !== null) {
          return la - lb;
        }
        return 0;
      });
    }
    this.nodes = rows;
  }

  /** 排序权重: 0=有延迟值 1=未测/不支持 2=失败(-1) */
  private latencyRank(latency: number | null): number {
    if (latency === null || latency === -2) {
      return 1;
    }
    if (latency < 0) {
      return 2;
    }
    return 0;
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
    this.testingName = node.name;
    const delay = await this.testNodeDelay(node);
    if (delay !== -2) { // -2 = 协议不支持离线测试, 保持"未测试"态
      LatencyController.set(node.name, delay);
    }
    this.testingName = '';
  }

  /**
   * 测速策略（回应"没启动 VPN 测通、启动后却超时"的误报）：
   * 未连接时先懒加载一个 headless 内核（不建 TUN、不请求 VPN 授权），
   * 走 /proxies/{name}/delay 真实协议测速 —— 与连上后同一套判定；
   * 内核拉不起来时才回退 DirectLatencyTester 的 TCP/QUIC 探测。
   * 已连接时直接走 Clash API。
   */
  private async testNodeDelay(node: ProxyNode): Promise<number> {
    if (this.isConnected) {
      return this.orchestrator.api.testLatency(node.name, this.settings.testLatencyUrl);
    }
    if (!this.testCoreTried) {
      this.testCoreTried = true;
      this.testCoreOk = await this.orchestrator.ensureTestCore(this.subs, this.settings);
    }
    if (this.testCoreOk) {
      return this.orchestrator.api.testLatency(node.name, this.settings.testLatencyUrl);
    }
    return DirectLatencyTester.testNode(node);
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

  private async testAll(): Promise<void> {
    if (this.batchTesting) {
      return;
    }
    this.batchTesting = true;
    const list = this.nodes.map((r) => r.node);
    // 并发测速池(12 路): 串行时 89 节点 × 最长 4-7s 超时 = 数分钟;
    // 并发后总耗时 ≈ max(单节点耗时) × ceil(N/12), 结果逐条即时回写。
    let cursor = 0;
    const workers: Promise<void>[] = [];
    const lanes = Math.min(12, list.length);
    for (let w = 0; w < lanes; w++) {
      workers.push((async (): Promise<void> => {
        for (;;) {
          if (!this.batchTesting) {
            return; // 批次被取消
          }
          const i = cursor;
          cursor = cursor + 1;
          if (i >= list.length) {
            return;
          }
          const delay = await this.testNodeDelay(list[i]);
          if (delay !== -2) {
            LatencyController.set(list[i].name, delay);
          }
        }
      })());
    }
    await Promise.all(workers);
    this.batchTesting = false;
    this.testingName = '';
    // 测速完成 → 按延迟从低到高重排(失败/未测沉底)
    this.sortByLatency = true;
    this.rebuildRows();
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
          Blank()
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
              .constraintSize({ maxWidth: 220 })
          }
          Blank()
          // 刷新(重载节点/订阅) + 闪电(测速) 图标组
          Row({ space: 14 }) {
            Text(this.refreshing ? '◌' : '⟳')
              .fontSize(22)
              .fontColor(this.refreshing ? Ui.primary : '#F2F4FF')
              .onClick(() => this.refreshNodes())
            Text(this.batchTesting ? '⏳' : '⚡')
              .fontSize(21)
              .fontColor(this.batchTesting ? Ui.primary : '#F2F4FF')
              .onClick(() => {
                if (this.batchTesting) {
                  this.batchTesting = false;
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
          .backgroundColor('#66182038')
        }
        .width('100%')
        .padding(16)
        .borderRadius(20)
        .backgroundColor('#E0242641')
        .borderWidth(1)
        .borderColor(Ui.border)
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
          .backgroundColor('#293675FF')
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
          .backgroundColor('#293675FF')
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
        .backgroundColor('#2920C8B4')
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
                .backgroundColor(this.filterSubId.length === 0 ? '#29' + Ui.primary.substring(1) : Ui.surface)
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
                  .backgroundColor(this.filterSubId === chip.id ? '#29' + Ui.primary.substring(1) : Ui.surface)
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

        // ── 节点列表 ──
        Text('长按节点可删除 · 测速走真实协议栈(不建隧道不弹授权)')
          .fontSize(11).fontColor(Ui.textTertiary)
          .margin({ top: 6, bottom: 2 })
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
        .fontColor(this.proxyMode === mode ? '#B9AEFF' : Ui.textSecondary)
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.proxyMode === mode ? '#B9AEFF' : Ui.textSecondary)
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .padding({ top: 9, bottom: 9 })
    .borderRadius(11)
    .backgroundColor(this.proxyMode === mode ? '#406A5CFF' : Color.Transparent)
    .borderWidth(this.proxyMode === mode ? 1 : 0)
    .borderColor(this.proxyMode === mode ? '#8C7FFF' : Color.Transparent)
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
  @Builder
  NodeCard(row: NodeRow) {
    Row() {
      Row({ space: 12 }) {
        CountryFlagIcon({ nodeName: row.node.name, iconSize: 26 })
        Text(NodeDisplay.compact(NodeDisplay.withoutLeadingFlag(row.node.name)))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(row.node.name === this.selectedName ? Ui.primary : Ui.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .layoutWeight(1)
      .onClick(() => this.selectNode(row.node))

      Text(this.testingName === row.node.name ? '…' : LatencyStyle.text(LatencyController.latencyFor(row.node.name)))
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(LatencyStyle.color(LatencyController.latencyFor(row.node.name)))
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
    .backgroundColor(row.node.name === this.selectedName ? Ui.surfaceStrong : '#E0242641')
    .borderWidth(1)
    .borderColor(row.node.name === this.selectedName ? '#94' + Ui.primary.substring(1) : Ui.border)
  }
}
