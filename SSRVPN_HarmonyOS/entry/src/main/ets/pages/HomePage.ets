/**
 * HomePage - 1:1 aligned with upstream SsrvpnHomeOverview
 */
import { router, promptAction } from '@kit.ArkUI';
import { Ui, LatencyStyle, NodeDisplay } from '../theme/UiTokens';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { SettingsService } from '../commons/services/SettingsService';
import { PublicIpService } from '../commons/services/PublicIpService';
import { PublicIpInfo } from '../commons/models/PublicIpInfo';
import { ProxyNode } from '../commons/models/ProxyNode';
import { AppSettings } from '../commons/models/AppSettings';
import { LatencyController } from '../commons/services/LatencyController';
import { ConnectionSnapshot } from '../commons/services/SettingsService';
import { NodeCountryPolicy } from '../commons/services/PublicIpService';
import { CountryFlagIcon } from '../widgets/CountryFlagIcon';
import { DiagnosticsSheet } from '../widgets/DiagnosticsSheet';
import { PowerButton } from '../components/PowerButton';
import { AppLogger } from '../commons/utils/AppLogger';
import { AppInfo } from '../commons/utils/AppInfo';

const TAG = 'HomePage';

@CustomDialog
struct AboutDialog {
  controller?: CustomDialogController;
  onClose: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('SSRVPN').fontSize(30).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text(`for HarmonyOS v${AppInfo.version()}`).fontSize(13).fontColor(Ui.textTertiary)
      Text('Mihomo (Clash Meta) 客户端 · MIT License')
        .fontSize(12).fontColor(Ui.textSecondary)
      // 检查更新暂不启用（后续需要时再接入自有更新源）
      Button('关闭')
        .width('100%')
        .backgroundColor(Ui.primaryBlue)
        .fontColor(Color.White)
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })
    }
    .padding(26)
    .borderRadius(20)
    .backgroundColor('#E6242641')
    .borderWidth(1)
    .borderColor(Ui.border)
  }
}

@CustomDialog
struct TutorialDialog {
  controller?: CustomDialogController;
  onClose: () => void = () => {};

  private steps: string[] = [
    '点击底部「订阅」标签，进入订阅管理页面',
    '在输入框中粘贴节点链接或订阅链接，点击「添加」',
    '添加成功后点击「全部刷新」，等待节点加载完成',
    '返回主页，点击连接按钮即可使用',
    '首次连接会弹出系统权限弹窗，选择「确定」允许即可'
  ];

  build() {
    Column({ space: 12 }) {
      Text('使用教程').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      ForEach(this.steps, (step: string, idx: number) => {
        Row({ space: 10 }) {
          Text(`${idx + 1}`)
            .fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(Ui.primaryBlue)
            .width(22).height(22)
            .borderRadius(11)
            .backgroundColor('#293675FF')
            .textAlign(TextAlign.Center)
          Text(step).fontSize(14).fontColor(Ui.textSecondary).layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (step: string) => step)
      Button('知道了')
        .width('100%')
        .backgroundColor(Ui.primaryBlue)
        .fontColor(Color.White)
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })
    }
    .padding(26)
    .borderRadius(20)
    .backgroundColor('#E6242641')
    .borderWidth(1)
    .borderColor(Ui.border)
  }
}

@Entry
@Component
struct HomePage {
  @State isConnected: boolean = false;
  @State isConnecting: boolean = false;
  @State errorMessage: string = '';
  @State publicIp: string = '';
  @State publicIpRefreshing: boolean = false;
  @State publicIpError: string = '';
  @State currentNodeName: string = '';
  @State currentLatencyTick: number = 0; // 延迟缓存变化时触发重渲染
  @State showDiagnostics: boolean = false;
  @State diagTick: number = 0;
  @State upSpeed: number = 0;
  @State downSpeed: number = 0;
  @State upTotal: number = 0;
  @State downTotal: number = 0;
  @State buttonPressed: boolean = false;
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = new SubscriptionService();
  private settings: AppSettings = new AppSettings();
  /** 防止 onPageShow 反复执行时重复注册监听（单例 orchestrator 的 listeners 会跨页存活） */
  private listenerBound: boolean = false;
  private latencyListenerBound: boolean = false;
  private aboutDialog: CustomDialogController = new CustomDialogController({
    builder: AboutDialog({})
  });
  private tutorialDialog: CustomDialogController = new CustomDialogController({
    builder: TutorialDialog({})
  });

  onPageShow(): void {
    this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await SettingsService.init(ctx);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    if (!this.listenerBound) {
      this.listenerBound = true;
      this.orchestrator.listeners.push(() => {
        this.isConnected = this.orchestrator.state === ConnState.CONNECTED;
        this.isConnecting = this.orchestrator.state === ConnState.CONNECTING
          || this.orchestrator.state === ConnState.DISCONNECTING
          || this.orchestrator.state === ConnState.RECOVERING;
        this.errorMessage = this.orchestrator.lastError;
        this.upSpeed = this.orchestrator.traffic.uploadSpeed;
        this.downSpeed = this.orchestrator.traffic.downloadSpeed;
        this.upTotal = this.orchestrator.traffic.uploadBytes;
        this.downTotal = this.orchestrator.traffic.downloadBytes;
        this.refreshDisplayNode();
      });
    }
    if (!this.latencyListenerBound) {
      this.latencyListenerBound = true;
      LatencyController.addListener(() => {
        this.currentLatencyTick = this.currentLatencyTick + 1;
      });
    }
    this.refreshDisplayNode();
    if (this.publicIp.length === 0) {
      await this.refreshPublicIp();
    }
    // 单例 orchestrator: 回到主页时立即同步真实状态(不依赖下一次 notify),
    // 已连接则 UI 直接显示"已连接", 也不会触发误重连。
    this.isConnected = this.orchestrator.state === ConnState.CONNECTED;
    this.isConnecting = this.orchestrator.state === ConnState.CONNECTING
      || this.orchestrator.state === ConnState.DISCONNECTING
      || this.orchestrator.state === ConnState.RECOVERING;
    this.errorMessage = this.orchestrator.lastError;
    // 不再自动恢复连接: 打开应用保持断开状态, 由用户手动点击启动。
  }

  /** 对齐 HomeNodeController.resolveDefaultNode / resolveRuntimeSelectedNode 的简化实现 */
  private refreshDisplayNode(): void {
    const preferred = this.subs.findNode(this.settings.preferredNodeId);
    if (preferred !== null) {
      this.currentNodeName = preferred.name;
      return;
    }
    if (this.subs.nodes.length > 0) {
      this.currentNodeName = this.subs.nodes[0].name;
      return;
    }
    this.currentNodeName = '';
  }

  private selectedNode(): ProxyNode | null {
    return this.subs.findNode(this.settings.preferredNodeId)
      ?? (this.subs.nodes.length > 0 ? this.subs.nodes[0] : null);
  }

  private statusText(): string {
    if (this.isConnecting) {
      return this.isConnected ? '正在断开' : '正在连接';
    }
    if (this.errorMessage.length > 0) {
      return '连接异常';
    }
    if (this.isConnected) {
      return '已连接';
    }
    return '未连接';
  }

  private statusColor(): string {
    if (this.isConnecting) {
      return Ui.warning;
    }
    if (this.errorMessage.length > 0) {
      return Ui.error;
    }
    if (this.isConnected) {
      return Ui.success;
    }
    return Ui.textSecondary;
  }

  private powerColor(): string {
    if (this.errorMessage.length > 0) {
      return Ui.error;
    }
    return this.isConnected ? Ui.success : Ui.primary;
  }

  private async refreshPublicIp(): Promise<void> {
    this.publicIpRefreshing = true;
    this.publicIpError = '';
    const info: PublicIpInfo = await PublicIpService.query();
    if (info.ip.length > 0) {
      this.publicIp = info.ip;
    } else {
      this.publicIp = '';
      this.publicIpError = '获取公网 IPv4 失败，点击重试';
    }
    this.publicIpRefreshing = false;
  }

  private async toggleConnection(): Promise<void> {
    if (this.isConnecting) {
      await this.orchestrator.disconnect();
      return;
    }
    if (this.isConnected) {
      await this.orchestrator.disconnect();
      this.refreshPublicIp();
      return;
    }
    const node = this.selectedNode();
    if (node === null) {
      promptAction.showToast({ message: '暂无可用节点，请先在「订阅」页添加并刷新' });
      return;
    }
    const ok = await this.orchestrator.connect(node, this.subs);
    if (ok) {
      this.refreshPublicIp();
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ── 背景（SsrvpnAppBackdrop：三段对角渐变） ──
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 135,
          colors: Ui.backdropColors
        })
        // 背景延伸到状态栏/底部导航条之下, 配合透明系统栏呈现主题色
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Scroll() {
          Column({ space: 0 }) {
            // ── 头部：关于 | SSRVPN | 使用教程 ──
            Row() {
              Text('关于')
                .fontSize(14).fontColor(Ui.textSecondary)
                .padding({ left: 4, right: 4 })
                .onClick(() => this.aboutDialog.open())
              Blank()
              Text('SSRVPN')
                .fontSize(29)
                .fontWeight(FontWeight.Normal)
                .fontColor(Ui.textPrimary)
                .letterSpacing(0.4)
              Blank()
              Text('使用教程')
                .fontSize(14).fontColor(Ui.textSecondary)
                .padding({ left: 4, right: 4 })
                .onClick(() => this.tutorialDialog.open())
            }
            .width('100%')
            .height(54)

            Blank().height(10)

            // ── 状态胶囊 ──
            Row({ space: 8 }) {
              Circle({ width: 8, height: 8 }).fill(this.statusColor())
              Text(this.statusText())
                .fontSize(13).fontWeight(FontWeight.Bold)
                .fontColor(this.statusColor())
            }
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(18)
            .backgroundColor('#B8242641') // surface 72%
            .borderWidth(1)
            .borderColor(this.statusColor() === Ui.textSecondary ? '#2EA7AFC2' : '#2EFFFFFF')

            Blank().height(42)

            // ── 电源按钮（PowerButton 组件: 外环描边+内圆+SVG 电源图标） ──
            PowerButton({
              isConnected: this.isConnected,
              isConnecting: this.isConnecting,
              hasError: this.errorMessage.length > 0,
              buttonSize: 210,
              onToggle: () => {
                this.toggleConnection();
              }
            })

            Blank().height(58)

            // ── 当前节点卡 ──
            this.CurrentNodeCard()

            // ── 数据面板: 三格横排(上传速率/下载速率/本次累计), 常驻显示。
            // 直接内联在 build() 内: @Builder 值传参没有状态观察,
            // 真机实测 @State 变化不刷新独立 builder, 面板会永远停在 0。 ──
            Blank().height(14)
            Row({ space: 10 }) {
              Column({ space: 4 }) {
                Row({ space: 5 }) {
                  Text('↑').fontSize(13).fontColor(Ui.primaryBlue)
                  Text(this.formatSpeedValue(this.upSpeed))
                    .fontSize(15).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                    .maxLines(1)
                }
                .alignItems(VerticalAlign.Center)
                Text('上传速率').fontSize(11).fontColor(Ui.textSecondary)
              }
              .alignItems(HorizontalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .padding({ top: 12, bottom: 12 })
              .borderRadius(14)
              .backgroundColor('#E0242641')
              .borderWidth(1)
              .borderColor(Ui.border)

              Column({ space: 4 }) {
                Row({ space: 5 }) {
                  Text('↓').fontSize(13).fontColor(Ui.success)
                  Text(this.formatSpeedValue(this.downSpeed))
                    .fontSize(15).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                    .maxLines(1)
                }
                .alignItems(VerticalAlign.Center)
                Text('下载速率').fontSize(11).fontColor(Ui.textSecondary)
              }
              .alignItems(HorizontalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .padding({ top: 12, bottom: 12 })
              .borderRadius(14)
              .backgroundColor('#E0242641')
              .borderWidth(1)
              .borderColor(Ui.border)

              Column({ space: 4 }) {
                Row({ space: 5 }) {
                  Text('Σ').fontSize(13).fontColor(Ui.accent)
                  Text(this.formatBytesValue(this.upTotal + this.downTotal))
                    .fontSize(15).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                    .maxLines(1)
                }
                .alignItems(VerticalAlign.Center)
                Text('本次累计').fontSize(11).fontColor(Ui.textSecondary)
              }
              .alignItems(HorizontalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .padding({ top: 12, bottom: 12 })
              .borderRadius(14)
              .backgroundColor('#E0242641')
              .borderWidth(1)
              .borderColor(Ui.border)
            }
            .width('100%')
            .constraintSize({ maxWidth: 408 })

            // ── 连接详情 / 公网 IP ──
            if (this.isConnected || this.errorMessage.length > 0) {
              Blank().height(14)
              if (this.errorMessage.length > 0) {
                Row({ space: 6 }) {
                  Text('⚠').fontSize(16).fontColor(Ui.error)
                  Text(this.errorMessage).fontSize(13).fontColor(Ui.error).layoutWeight(1)
                }
                .width('100%')
                .onClick(() => { this.showDiagnostics = true; })
              } else {
                Row({ space: 6 }) {
                  if (this.publicIpRefreshing) {
                    LoadingProgress().width(15).height(15).color(Ui.textSecondary)
                  } else {
                    Text('🌐').fontSize(15)
                  }
                  Text(this.publicIpRefreshing ? '正在获取公网 IPv4…'
                    : (this.publicIp.length > 0 ? `公网 IPv4  ${this.publicIp}` : this.publicIpError))
                    .fontSize(13).fontColor(Ui.textSecondary)
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  if (!this.publicIpRefreshing) {
                    this.refreshPublicIp();
                  }
                })
              }
            }
          }
          .constraintSize({ maxWidth: Ui.pageMaxWidth })
          .padding({ left: 18, right: 18, top: 14, bottom: 130 })
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')

      // ── 浮动底部导航（对齐 SsrvpnBottomNavigation） ──
      this.BottomNav()

      if (this.showDiagnostics) {
        Column() {
          Blank()
          DiagnosticsSheet({
            darkMode: true,
            diag: null,
            onRefresh: () => {
              this.orchestrator.diagnostics();
              this.diagTick = this.diagTick + 1;
            },
            onClose: () => { this.showDiagnostics = false; }
          })
            .height('55%')
        }
        .width('100%').height('100%')
        .backgroundColor('#99000000')
        .onClick(() => { this.showDiagnostics = false; })
      }
    }
    .width('100%').height('100%')
  }

  /** 当前节点卡（对齐 SsrvpnCurrentNodeCard） */
  @Builder
  CurrentNodeCard() {
    Column() {
      // 内联卡片样式（自定义组件 builder 跨组件传 UI 在部分设备上布局异常，改用内联）
      Row() {
        Column() {
          Text('✦').fontSize(24).fontColor(Color.White)
        }
        .width(48).height(48)
        .borderRadius(15)
        .backgroundColor(Ui.primary)
        .justifyContent(FlexAlign.Center)
        .shadow({ radius: 18, color: '#47' + Ui.primary.substring(1), offsetY: 8 })

        Column({ space: 4 }) {
          Text('当前节点').fontSize(12).fontColor(Ui.textSecondary)
          Row({ space: 7 }) {
            CountryFlagIcon({
              nodeName: this.currentNodeName.length > 0 ? this.currentNodeName : 'UN',
              iconSize: 22
            })
            Text(this.currentNodeName.length > 0
              ? NodeDisplay.compact(NodeDisplay.withoutLeadingFlag(this.currentNodeName))
              : '暂无可用节点')
              .fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(Ui.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          Text(LatencyStyle.text(LatencyController.latencyFor(this.currentNodeName)))
            .fontSize(12)
            .fontColor(LatencyStyle.color(LatencyController.latencyFor(this.currentNodeName)))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 })

        Text('›').fontSize(24).fontColor(Ui.textSecondary).margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .borderRadius(22)
      .backgroundColor('#E0242641')
      .borderWidth(1)
      .borderColor(Ui.border)
      .shadow({ radius: 28, color: '#38000000', offsetY: 14 })
    }
    .width('100%')
    .constraintSize({ maxWidth: 408 })
    .onClick(() => {
      router.pushUrl({ url: 'pages/NodeSelectionPage' });
    })
  }

  private formatSpeedValue(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${Math.round(bytesPerSecond)} B/s`;
    }
    const kb = bytesPerSecond / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB/s`;
    }
    return `${(kb / 1024).toFixed(1)} MB/s`;
  }

  private formatBytesValue(bytes: number): string {
    if (bytes < 1024) {
      return `${Math.round(bytes)} B`;
    }
    const kb = bytes / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  /** 浮动底部导航（对齐 SsrvpnBottomNavigation） */
  @Builder
  BottomNav() {
    Column({ space: 6 }) {
      Row() {
        this.NavItem(true, '⌂', '主页', () => {})
        this.NavItem(false, '☰', '订阅', () => {
          // 底部导航栏在主页/订阅页都有, 用 replaceUrl 切换避免路由栈无限堆叠
          router.replaceUrl({ url: 'pages/SubscriptionPage' });
        })
      }
      .width('100%')
      .padding(6)
      .constraintSize({ minHeight: 72 })
      .borderRadius(28)
      .backgroundColor('#F024263A')
      .borderWidth(1)
      .borderColor(Ui.border)
      .shadow({ radius: 30, color: '#66000000', offsetY: 16 })
      .shadow({ radius: 20, color: '#242F5BFF', offsetY: 5 })

      Text(`SSRVPN for HarmonyOS v${AppInfo.version()}`)
        .fontSize(11).fontColor(Ui.textTertiary)
    }
    .width('92%')
    .constraintSize({ maxWidth: Ui.bottomNavMaxWidth })
    .margin({ bottom: 10 })
  }

  @Builder
  NavItem(selected: boolean, icon: string, label: string, onTap: () => void) {
    Column({ space: 2 }) {
      Text(icon).fontSize(20).fontColor(selected ? Ui.textPrimary : Ui.textSecondary)
      Text(label)
        .fontSize(12)
        .fontWeight(selected ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(selected ? Ui.textPrimary : Ui.textSecondary)
    }
    .layoutWeight(1)
    .constraintSize({ minWidth: 0 })
    .padding({ top: 8, bottom: 8 })
    .borderRadius(22)
    .backgroundColor(selected ? '#29' + Ui.primary.substring(1) : Color.Transparent)
    .onClick(() => onTap())
  }
}
