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
          .backgroundColor(Ui.primaryBlue)
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
  @State subChips: SubChip[] = []; // 响应式订阅筛选列表（onPageShow 异步加载后刷新）
  @State selectedName: string = '';
  @State testingName: string = '';
  @State batchTesting: boolean = false;
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
    this.rebuildRows();
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
    this.nodes = rows;
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
    LatencyController.set(node.name, delay);
    this.testingName = '';
  }

  /** 未连接时走直连 TCP 握手测速(内核未启动 API 不存在), 已连接时走 Clash API(经代理真实路径) */
  private async testNodeDelay(node: ProxyNode): Promise<number> {
    if (!this.isConnected) {
      return DirectLatencyTester.testNode(node);
    }
    return this.orchestrator.api.testLatency(node.name, this.settings.testLatencyUrl);
  }

  private async testAll(): Promise<void> {
    if (this.batchTesting) {
      return;
    }
    this.batchTesting = true;
    const list = this.nodes.map((r) => r.node);
    for (const n of list) {
      this.testingName = n.name;
      const delay = await this.testNodeDelay(n);
      LatencyController.set(n.name, delay);
    }
    this.testingName = '';
    this.batchTesting = false;
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
              .fontSize(13).fontWeight(FontWeight.Medium).fontColor(Ui.primaryBlue)
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
              .fontSize(13).fontWeight(FontWeight.Medium).fontColor(Ui.primaryBlue)
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
        if (this.nodes.length === 0) {
          Column({ space: 12 }) {
            Text('🖧').fontSize(46).fontColor(Ui.textTertiary)
            Text('暂无可用节点').fontSize(15).fontColor(Ui.textSecondary)
          }
          .width('100%')
          .margin({ top: 120 })
        } else {
          List({ space: 7 }) {
            ForEach(this.nodes, (row: NodeRow) => {
              ListItem() {
                this.NodeCard(row)
              }
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
