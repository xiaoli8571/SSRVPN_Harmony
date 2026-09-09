/**
 * 订阅页 — 1:1 对齐 upstream SsrvpnSubscriptionView（ssrvpn_subscription_view.dart 系）
 * 结构：头部(订阅管理) + 添加卡(图标标题+输入框+添加按钮) + 列表头(我的订阅+计数徽标+全部刷新)
 *       + 刷新结果条 + 订阅卡(渐变图标/名称/脱敏URL/编辑/删除/启用点/更新时间) + 空态 + 撤销条。
 * 删除为确认对话框；长按卡片进入编辑对话框；结果用 Toast 提示。所有卡片均为内联样式。
 * 日志：顶栏「日志」打开 诊断与运行日志 面板（对齐 upstream AppDiagnosticsView:
 *       结论摘要 + 复制报告/重新检查 + 诊断项卡片 + 最近运行记录 + 技术明细可展开）。
 */
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Ui } from '../theme/UiTokens';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { Subscription, SubscriptionRefreshStatus } from '../commons/models/Subscription';
import { SubscriptionFetchPolicy } from '../commons/services/SubscriptionFetchPolicy';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings } from '../commons/models/AppSettings';
import { AppLogger } from '../commons/utils/AppLogger';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { AppDiagnostics } from '../commons/models/PublicIpInfo';
import { AppInfo } from '../commons/utils/AppInfo';
const TAG = 'SubscriptionPage';

/** 单条可读日志（对齐 upstream AppDiagnosticLogEntry 展示字段） */
class ReadableLog {
  timeLabel: string = '';
  level: string = '';       // 信息 / 提醒 / 错误
  category: string = '';    // 模块标签, 如 ConnectionOrchestrator
  message: string = '';
}

/** 诊断项（对齐 upstream AppDiagnosticCheck 卡片展示） */
class DiagCheck {
  title: string = '';
  summary: string = '';
  passed: boolean = false;
  tone: string = 'ok';      // ok / warn / fail
}

@CustomDialog
struct DeleteConfirmDialog {
  controller?: CustomDialogController;
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('⚠️').fontSize(44)
      Text('确认删除').fontSize(18).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text('删除后将无法恢复，确定要删除吗？')
        .fontSize(13).fontColor(Ui.textSecondary).textAlign(TextAlign.Center)
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
        Button('删除')
          .layoutWeight(1)
          .backgroundColor(Ui.error)
          .fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm();
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

@CustomDialog
struct EditSubscriptionDialog {
  controller?: CustomDialogController;
  @State editName: string = '';
  @State editUrl: string = '';
  getInitialName: () => string = () => '';
  getInitialUrl: () => string = () => '';
  onConfirm: (name: string, url: string) => void = () => {};

  aboutToAppear(): void {
    // 每次 open 都会重建弹窗组件，此时从 getter 拉取当前目标值
    this.editName = this.getInitialName();
    this.editUrl = this.getInitialUrl();
  }

  build() {
    Column({ space: 14 }) {
      Text('编辑订阅').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1A1F2E')
      TextInput({ placeholder: '订阅名称', text: this.editName })
        .onChange((v: string) => { this.editName = v; })
        .height(46).borderRadius(12)
        .backgroundColor('#F5F7FF')
        .fontColor('#1A1F2E')
        .placeholderColor('#8A93A6')
      TextInput({ placeholder: '订阅链接', text: this.editUrl })
        .onChange((v: string) => { this.editUrl = v; })
        .height(46).borderRadius(12)
        .backgroundColor('#F5F7FF')
        .fontColor('#1A1F2E')
        .placeholderColor('#8A93A6')
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
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm(this.editName, this.editUrl);
          })
      }
      .width('100%')
    }
    .padding(24)
    .borderRadius(20)
    .backgroundColor('#F0F2F8')
    .borderWidth(1)
    .borderColor('#C9CEDC')
  }
}

/**
 * 诊断与运行日志 弹窗（1:1 对齐 upstream showSsrvpnDiagnosticsDialog + AppDiagnosticsView:
 * 居中对话框、#0E1018 深底、圆角16; 标题行(🐞+✕) → 结论摘要 → [复制报告][重新检查]
 * → 诊断项卡片 → 最近运行记录(可展开) → 技术明细(已脱敏,可展开) → 清空） */
@CustomDialog
struct DiagnosticsLogDialog {
  controller?: CustomDialogController;
  @State diagLoading: boolean = false;
  @State diagSummary: string = '';
  @State diagChecks: DiagCheck[] = [];
  @State readableLogs: ReadableLog[] = [];
  @State runLogLines: string[] = [];
  @State runLogTick: number = 0;
  @State logCopied: boolean = false;
  @State showReadable: boolean = true;
  @State showTechnical: boolean = false;
  /** 实时日志监听器（弹窗销毁时移除, 避免泄漏） */
  private onLogLine: (line: string) => void = (line: string) => {
    this.runLogLines.push(line);
    if (this.runLogLines.length > 300) {
      this.runLogLines.splice(0, this.runLogLines.length - 300);
    }
    this.readableLogs = DiagnosticsLogDialog.parseLogs(this.runLogLines);
    this.runLogTick = this.runLogTick + 1;
  };

  aboutToAppear(): void {
    AppLogger.addListener(this.onLogLine);
    this.recheck();
  }

  aboutToDisappear(): void {
    AppLogger.removeListener(this.onLogLine);
  }

  build() {
    Column({ space: 10 }) {
      // ── 标题行（对齐 upstream Dialog header） ──
      Row({ space: 8 }) {
        Text('🐞').fontSize(18).fontColor(Ui.warning)
        Text('诊断与运行日志')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
          .layoutWeight(1)
        Text('✕')
          .fontSize(18).fontColor(Ui.textSecondary)
          .padding(6)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')

      Divider().color(Ui.border)

      // ── 结论摘要 + 操作（对齐 upstream summaryText + summaryActions） ──
      Text(this.diagSummary.length > 0 ? this.diagSummary : '正在诊断…')
        .fontSize(13).fontColor(Ui.textSecondary)
        .width('100%')
      Row({ space: 12 }) {
        Text(this.logCopied ? '✓ 诊断报告已复制（敏感内容已脱敏）' : '📋 复制报告')
          .fontSize(13).fontColor(this.logCopied ? Ui.success : Ui.primaryBlue)
          .onClick(() => this.copyRunLog())
        Blank()
        Row({ space: 6 }) {
          if (this.diagLoading) {
            LoadingProgress().width(14).height(14).color(Ui.primaryBlue)
          } else {
            Text('🔄').fontSize(13)
          }
          Text('重新检查')
            .fontSize(13).fontColor(Ui.primaryBlue)
        }
        .onClick(() => {
          this.recheck();
        })
      }
      .width('100%')

      // ── 可滚动主体（诊断项 + 日志区） ──
      Scroll() {
        Column({ space: 8 }) {
          // 诊断项卡片（对齐 upstream _DiagnosticCheckTile）
          ForEach(this.diagChecks, (c: DiagCheck, idx: number) => {
            Row({ space: 10 }) {
              Text(this.checkIcon(c.tone))
                .fontSize(17)
                .fontColor(this.checkColor(c.tone))
              Column({ space: 3 }) {
                Text(c.title)
                  .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Ui.textPrimary)
                Text(c.summary)
                  .fontSize(12).fontColor(Ui.textSecondary)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(this.checkStatus(c.tone))
                .fontSize(12).fontColor(this.checkColor(c.tone))
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding(12)
            .borderRadius(12)
            .backgroundColor('#171B2A')
          }, (c: DiagCheck, idx: number) => `${idx}-${c.tone}-${c.summary}-${this.runLogTick}`)

          // 最近运行记录（对齐 upstream ExpansionTile: 有错误时默认展开）
          Row({ space: 8 }) {
            Text('📄').fontSize(15)
            Text(`最近运行记录（${this.readableLogs.length}）`)
              .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Ui.textPrimary)
            Blank()
            Text(this.showReadable ? '▾' : '▸')
              .fontSize(14).fontColor(Ui.textSecondary)
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .onClick(() => {
            this.showReadable = !this.showReadable;
          })

          if (this.showReadable) {
            ForEach(this.readableLogs.slice(-60), (e: ReadableLog, idx: number) => {
              Column({ space: 4 }) {
                Row({ space: 8 }) {
                  Text(e.level)
                    .fontSize(10).fontWeight(FontWeight.Bold)
                    .fontColor(this.entryLevelColor(e.level))
                  Text(e.category)
                    .fontSize(10).fontColor(Ui.textSecondary)
                  Text(e.timeLabel)
                    .fontSize(10).fontColor(Ui.textTertiary)
                }
                .width('100%')
                Text(e.message)
                  .fontSize(11).fontColor(Ui.textSecondary)
                  .width('100%')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor('#101420')
            }, (e: ReadableLog, idx: number) => `r${idx}-${this.runLogTick}`)
          }

          // 技术明细（已脱敏, monospace 全文, 默认收起）
          Row({ space: 8 }) {
            Text('⌨').fontSize(14).fontColor(Ui.textSecondary)
            Text('技术明细（已脱敏）')
              .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Ui.textPrimary)
            Text('仅在需要深入排障时查看')
              .fontSize(10).fontColor(Ui.textTertiary)
            Blank()
            Text(this.showTechnical ? '▾' : '▸')
              .fontSize(14).fontColor(Ui.textSecondary)
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .onClick(() => {
            this.showTechnical = !this.showTechnical;
          })

          if (this.showTechnical) {
            Text(this.runLogLines.slice(-200).join('\n'))
              .fontSize(10)
              .fontFamily('monospace')
              .fontColor(Ui.textSecondary)
              .width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor('#0D1120')
              .copyOption(CopyOptions.LocalDevice)
          }
        }
        .width('100%')
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
      .align(Alignment.Top)

      // ── 清空 ──
      Row() {
        Blank()
        Text('清空日志')
          .fontSize(12).fontColor(Ui.textTertiary)
          .padding(6)
          .onClick(() => {
            AppLogger.clear();
            this.runLogLines = [];
            this.readableLogs = [];
            this.runLogTick = this.runLogTick + 1;
          })
      }
      .width('100%')
    }
    // 弹窗尺寸样式（对齐 upstream Dialog: 0E1018 底 / 圆角16 / 约束宽高）
    .width('92%')
    .constraintSize({ maxWidth: 520 })
    .height('62%')
    .padding(18)
    .borderRadius(16)
    .backgroundColor('#0E1018')
    .borderWidth(1)
    .borderColor('#2A2E45')
  }

  private checkIcon(tone: string): string {
    if (tone === 'ok') {
      return '✅';
    }
    return tone === 'warn' ? '⚠' : '❌';
  }

  private checkStatus(tone: string): string {
    if (tone === 'ok') {
      return '通过';
    }
    return tone === 'warn' ? '提醒' : '失败';
  }

  private checkColor(tone: string): string {
    if (tone === 'ok') {
      return Ui.success;
    }
    return tone === 'warn' ? Ui.warning : Ui.error;
  }

  private entryLevelColor(level: string): string {
    if (level === '错误') {
      return Ui.error;
    }
    return level === '提醒' ? Ui.warning : Ui.primaryBlue;
  }

  /** 重新诊断（对齐 upstream _load: 跑诊断 + 读日志 + 汇总结论） */
  private async recheck(): Promise<void> {
    this.diagLoading = true;
    try {
      const orch = ConnectionOrchestrator.instance();
      orch.init(getContext(this) as Context);
      const d: AppDiagnostics = await orch.diagnostics();
      const checks: DiagCheck[] = [];
      const c1 = new DiagCheck();
      c1.title = '内核运行';
      c1.summary = d.coreRunning ? 'Mihomo 内核正在运行' : '内核未运行';
      c1.tone = d.coreRunning ? 'ok' : 'fail';
      checks.push(c1);
      const c2 = new DiagCheck();
      c2.title = 'VPN 激活';
      c2.summary = d.vpnActive ? '隧道已建立' : '隧道未建立';
      c2.tone = d.vpnActive ? 'ok' : 'warn';
      checks.push(c2);
      const c3 = new DiagCheck();
      c3.title = 'Clash API';
      c3.summary = d.clashApiReachable ? `可达 :${d.clashApiPort}` : '不可达';
      c3.tone = d.clashApiReachable ? 'ok' : 'fail';
      checks.push(c3);
      const c4 = new DiagCheck();
      c4.title = '运行时长';
      c4.summary = d.uptimeSeconds > 0 ? `${d.uptimeSeconds}s` : '—';
      c4.tone = d.uptimeSeconds > 0 ? 'ok' : 'warn';
      checks.push(c4);
      const cv6 = new DiagCheck();
      cv6.title = 'IPv6 入站';
      cv6.summary = orch.ipv6Active ? '环境存在 IPv6 出口, 双栈已启用' : '当前环境无 IPv6, 已自动绕过(纯 IPv4)';
      cv6.tone = 'ok';
      checks.push(cv6);
      if (d.lastError.length > 0) {
        const c5 = new DiagCheck();
        c5.title = '最近错误';
        c5.summary = d.lastError;
        c5.tone = 'fail';
        checks.push(c5);
      }
      let failed = 0;
      let warned = 0;
      for (const c of checks) {
        if (c.tone === 'fail') {
          failed = failed + 1;
        } else if (c.tone === 'warn') {
          warned = warned + 1;
        }
      }
      if (failed > 0) {
        this.diagSummary = `发现 ${failed} 项失败${warned > 0 ? `、${warned} 项提醒` : ''}，见下方明细`;
      } else if (warned > 0) {
        this.diagSummary = `${warned} 项提醒，无致命问题`;
      } else {
        this.diagSummary = '全部检查通过';
      }
      this.diagChecks = checks;
    } catch (e) {
      this.diagSummary = '诊断未能完成，请稍后重试';
    }
    this.runLogLines = AppLogger.dump().slice(-300);
    this.readableLogs = DiagnosticsLogDialog.parseLogs(this.runLogLines);
    this.showReadable = this.readableLogs.some((entry: ReadableLog) => entry.level === '错误');
    this.runLogTick = this.runLogTick + 1;
    this.diagLoading = false;
  }

  /** 解析 AppLogger 行: "<ISO时间> <LEVEL> <tag>: <message>" → 可读条目 */
  private static parseLogs(lines: string[]): ReadableLog[] {
    const out: ReadableLog[] = [];
    for (const line of lines) {
      const entry = new ReadableLog();
      const sp1 = line.indexOf(' ');
      if (sp1 <= 0) {
        entry.level = '信息';
        entry.message = line;
        out.push(entry);
        continue;
      }
      const ts = line.substring(0, sp1);
      const rest = line.substring(sp1 + 1);
      const sp2 = rest.indexOf(' ');
      const rawLevel = sp2 > 0 ? rest.substring(0, sp2) : '';
      const tail = sp2 > 0 ? rest.substring(sp2 + 1) : rest;
      const colon = tail.indexOf(':');
      entry.category = colon > 0 ? tail.substring(0, colon) : '';
      entry.message = colon > 0 ? tail.substring(colon + 1).trim() : tail;
      if (rawLevel === 'ERROR') {
        entry.level = '错误';
      } else if (rawLevel === 'WARN') {
        entry.level = '提醒';
      } else {
        entry.level = '信息';
      }
      const parsed = new Date(ts);
      if (!isNaN(parsed.getTime())) {
        const hh = `0${parsed.getHours()}`.slice(-2);
        const mm = `0${parsed.getMinutes()}`.slice(-2);
        const ss = `0${parsed.getSeconds()}`.slice(-2);
        entry.timeLabel = `${hh}:${mm}:${ss}`;
      }
      out.push(entry);
    }
    return out;
  }

  private copyRunLog(): void {
    // 复制完整诊断报告（对齐 upstream _copyReport, AppLogger 输出已脱敏）
    try {
      const parts: string[] = [`诊断结论: ${this.diagSummary}`];
      for (const c of this.diagChecks) {
        parts.push(`[${this.checkStatus(c.tone)}] ${c.title}: ${c.summary}`);
      }
      parts.push('');
      parts.push(this.runLogLines.join('\n'));
      const data = pasteboard.getSystemPasteboard();
      data.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, parts.join('\n')));
      this.logCopied = true;
      setTimeout(() => {
        this.logCopied = false;
      }, 2000);
    } catch (e) {
      promptAction.showToast({ message: '复制失败，请重试' });
    }
  }
}

@Entry
@Component
struct SubscriptionPage {
  @State subs: Subscription[] = [];
  @State inputUrl: string = '';
  @State isAdding: boolean = false;
  @State isRefreshing: boolean = false;
  @State refreshMessage: string = '';
  @State refreshMessageColor: string = Ui.primary;
  @State deleteTargetId: string = '';
  @State editTarget: Subscription | null = null;
  @State showUndoBanner: boolean = false;
  private service: SubscriptionService = new SubscriptionService();
  private settings: AppSettings = new AppSettings();
  private deleteDialog: CustomDialogController = new CustomDialogController({
    builder: DeleteConfirmDialog({
      onConfirm: () => {
        this.doDelete(this.deleteTargetId);
      }
    })
  });
  private editDialog: CustomDialogController = new CustomDialogController({
    builder: EditSubscriptionDialog({
      getInitialName: (): string => this.editTarget ? this.editTarget.name : '',
      getInitialUrl: (): string => this.editTarget ? this.editTarget.url : '',
      onConfirm: (name: string, url: string) => {
        this.doEdit(name, url);
      }
    })
  });
  /** 诊断与运行日志弹窗（对齐 upstream showSsrvpnDiagnosticsDialog 居中对话框） */
  private diagDialog: CustomDialogController = new CustomDialogController({
    builder: DiagnosticsLogDialog({}),
    customStyle: true,
    alignment: DialogAlignment.Center,
    autoCancel: true
  });

  onPageShow(): void {
    this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    await SettingsService.init(getContext(this) as Context);
    await this.service.init(getContext(this) as Context);
    this.settings = await SettingsService.load();
    this.reload();
  }

  private reload(): void {
    this.subs = this.service.subscriptions.slice();
  }

  private showError(msg: string): void {
    promptAction.showToast({ message: msg });
  }

  /** 对齐 upstream SubscriptionScreenController.addSubscription 的行为分支 */
  private async addSubscription(): Promise<void> {
    if (this.isAdding || this.isRefreshing) {
      return;
    }
    const raw = this.inputUrl.trim();
    if (raw.length === 0) {
      this.showError('请输入订阅或节点链接');
      return;
    }
    this.isAdding = true;
    try {
      if (SubscriptionService.isNodeUri(raw)) {
        const added = await this.service.addDirectNode(raw);
        if (added === 1) {
          this.showError(`节点链接已导入，当前共 ${this.service.nodes.length} 个节点`);
          this.inputUrl = '';
        } else if (added === -1) {
          this.showError('该节点已存在，无需重复添加');
        } else {
          this.showError('导入失败，请检查链接是否有效');
        }
        this.reload();
        this.isAdding = false;
        return;
      }
      if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(raw)) {
        this.showError('请输入有效的URL地址');
        this.isAdding = false;
        return;
      }
      const dupe = this.subs.find((s) => s.url === raw);
      if (dupe !== undefined) {
        this.showError('该订阅已存在，无需重复添加');
        this.isAdding = false;
        return;
      }
      const name = `订阅 ${this.subs.length + 1}`;
      const sub = await this.service.addSubscription(name, raw, '', '');
      this.reload();
      this.inputUrl = '';
      const result = await this.service.refreshSubscription(sub.id);
      this.reload();
      if (result.status === SubscriptionRefreshStatus.OK && result.nodeCount > 0) {
        this.showError(`订阅成功，获取到 ${result.nodeCount} 个节点`);
      } else if (result.status === SubscriptionRefreshStatus.OK) {
        this.showError('订阅已添加，但未获取到数据');
      } else if (result.status === SubscriptionRefreshStatus.PARSE_ERROR) {
        this.showError('订阅内容解析失败：未识别到可用节点（支持 ss/ssr/vless/vmess/trojan）');
      } else {
        this.showError('刷新失败，请检查网络后重试');
      }
    } catch (e) {
      this.showError('添加失败，请检查链接是否有效');
      AppLogger.error(TAG, `add failed: ${e instanceof Error ? e.message : String(e)}`);
    }
    this.isAdding = false;
  }

  /** 全部刷新（对应 SubscriptionScreenController.refreshAll） */
  private async refreshAll(): Promise<void> {
    if (this.isAdding || this.isRefreshing) {
      return;
    }
    this.isRefreshing = true;
    this.refreshMessage = '';
    let ok = 0;
    let fail = 0;
    let total = 0;
    const failReasons: string[] = [];
    for (const s of this.subs) {
      const r = await this.service.refreshSubscription(s.id);
      if (r.status === SubscriptionRefreshStatus.OK) {
        ok = ok + 1;
        total = total + r.nodeCount;
      } else {
        fail = fail + 1;
        const reason = r.message.length > 0 ? r.message : `${r.status}`;
        failReasons.push(`${s.name}: ${reason}`);
        AppLogger.warn(TAG, `refresh ${s.name} failed: ${reason}`);
      }
      this.reload();
    }
    this.isRefreshing = false;
    if (fail === 0) {
      this.refreshMessageColor = Ui.success;
      this.refreshMessage = `全部刷新成功，共 ${total} 个节点`;
    } else if (ok > 0) {
      this.refreshMessageColor = Ui.warning;
      this.refreshMessage = `部分刷新成功（${ok} 成功 / ${fail} 失败），共 ${total} 个节点；${failReasons.join('；')}`;
    } else {
      this.refreshMessageColor = Ui.error;
      this.refreshMessage = `刷新失败：${failReasons.join('；')}`;
    }
    this.reload();
  }

  private async doDelete(id: string): Promise<void> {
    await this.service.removeSubscription(id);
    this.reload();
    // 撤销条（对应 upstream SnackBar action）：5 秒内可撤销删除
    this.showUndoBanner = true;
    setTimeout(() => {
      this.showUndoBanner = false;
    }, 5000);
  }

  private async undoDelete(): Promise<void> {
    const ok = await this.service.undoRemove();
    this.showUndoBanner = false;
    this.reload();
    promptAction.showToast({ message: ok ? '已撤销删除' : '无可撤销的操作' });
  }

  private openEdit(sub: Subscription): void {
    this.editTarget = sub;
    if (this.editDialog !== null) {
      this.editDialog.open();
    }
  }

  private async doEdit(name: string, url: string): Promise<void> {
    const target = this.editTarget;
    if (target === null) {
      return;
    }
    if (name.trim().length === 0) {
      this.showError('订阅名称不能为空');
      return;
    }
    if (url.trim().length === 0) {
      this.showError('订阅链接不能为空');
      return;
    }
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(url.trim())) {
      this.showError('请输入有效的订阅链接');
      return;
    }
    const dupe = this.subs.find((s) => s.url === url.trim() && s.id !== target.id);
    if (dupe !== undefined) {
      this.showError('该订阅链接已存在');
      return;
    }
    target.name = name.trim();
    target.url = url.trim();
    await this.service.updateSubscription(target);
    this.reload();
    this.editTarget = null;
    this.showError('订阅已更新');
  }

  private formatUpdateTime(ts: number): string {
    if (ts <= 0) {
      return '未更新';
    }
    const diffMs = Date.now() - ts;
    const minutes = Math.floor(diffMs / 60000);
    if (minutes < 1) {
      return '更新于刚刚';
    }
    if (minutes < 60) {
      return `更新于 ${minutes}分钟前`;
    }
    const hours = Math.floor(minutes / 60);
    if (hours < 24) {
      return `更新于 ${hours}小时前`;
    }
    const days = Math.floor(hours / 24);
    if (days < 7) {
      return `更新于 ${days}天前`;
    }
    const d = new Date(ts);
    return `更新于 ${d.getMonth() + 1}/${d.getDate()}`;
  }

  private maskedUrl(url: string): string {
    return SubscriptionFetchPolicy.redactUrl(url);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%').height('100%')
        .linearGradient({ angle: 135, colors: Ui.backdropColors })
        // 背景延伸到状态栏/底部导航条之下, 消除底部白条
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Scroll() {
          Column() {
            // ── 头部（页面切换已由底部导航栏承担, 不再需要返回箭头） ──
            Row() {
              Text('订阅管理')
                .fontSize(17).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
              Blank()
              Text('日志')
                .fontSize(14).fontColor(Ui.textSecondary)
                .onClick(() => { this.diagDialog.open(); })
            }
            .width('100%')
            .padding({ left: 18, right: 18, top: 10, bottom: 6 })

            Column() {
              // ── 添加卡（对齐 _SubscriptionAddCard；内联样式） ──
              Column() {
                Row({ space: 10 }) {
                  Text('➕').fontSize(22)
                  Text('添加订阅').fontSize(19).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                }
                .width('100%')

                Blank().height(18)
                TextInput({ placeholder: '粘贴订阅或节点链接', text: this.inputUrl })
                  .onChange((v: string) => { this.inputUrl = v; })
                  .enabled(!(this.isAdding || this.isRefreshing))
                  .height(50)
                  .borderRadius(18)
                  .backgroundColor('#181B2A')
                  .fontColor(Ui.textPrimary)
                  .placeholderColor(Ui.textTertiary)
                  .padding({ left: 16, right: 16 })
                  .onSubmit(() => this.addSubscription())
                Blank().height(16)
                Button(this.isAdding ? '添加中…' : '添加')
                  .width('100%')
                  .height(52)
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
                  .backgroundColor(this.isAdding ? '#6B3675FF' : Ui.primaryBlue)
                  .borderRadius(16)
                  .enabled(!(this.isAdding || this.isRefreshing))
                  .onClick(() => this.addSubscription())
              }
              .width('100%')
              .padding(22)
              .borderRadius(24)
              .backgroundColor('#E0242641')
              .borderWidth(1)
              .borderColor(Ui.border)
              .shadow({ radius: 28, color: '#38000000', offsetY: 14 })

              Blank().height(30)

              // ── 列表头（对齐 _SubscriptionListHeader） ──
              Row() {
                Text('我的订阅')
                  .fontSize(21).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                Text(`${this.subs.length}`)
                  .fontSize(13).fontWeight(FontWeight.Bold)
                  .fontColor(Ui.primaryBlue)
                  .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                  .borderRadius(10)
                  .backgroundColor('#29' + Ui.primaryBlue.substring(1))
                  .margin({ left: 9 })
                Blank()
                Text(this.isRefreshing ? '取消刷新' : '全部刷新')
                  .fontSize(14).fontColor(Ui.primaryBlue)
                  .onClick(() => {
                    if (this.isRefreshing) {
                      this.isRefreshing = false;
                    } else {
                      this.refreshAll();
                    }
                  })
              }
              .width('100%')

              // ── 刷新结果条（对齐 _RefreshMessage） ──
              if (this.refreshMessage.length > 0) {
                Blank().height(10)
                Text(this.refreshMessage)
                  .fontSize(13)
                  .fontColor(this.refreshMessageColor)
                  .width('100%')
                  .padding(12)
                  .borderRadius(14)
                  .backgroundColor('#1F' + this.refreshMessageColor.substring(1))
                  .borderWidth(1)
                  .borderColor('#4D' + this.refreshMessageColor.substring(1))
              }

              // ── 撤销删除条 ──
              if (this.showUndoBanner) {
                Blank().height(10)
                Row() {
                  Text('订阅已删除').fontSize(13).fontColor(Ui.textSecondary).layoutWeight(1)
                  Text('撤销')
                    .fontSize(14).fontWeight(FontWeight.Bold).fontColor(Ui.accent)
                    .onClick(() => this.undoDelete())
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 10, bottom: 10 })
                .borderRadius(14)
                .backgroundColor(Ui.surface)
                .borderWidth(1)
                .borderColor(Ui.border)
              }

              Blank().height(14)

              // ── 订阅卡列表 / 空态 ──
              if (this.subs.length === 0) {
                Column({ space: 14 }) {
                  Text('📡').fontSize(48).fontColor(Ui.textTertiary)
                  Text('暂无订阅')
                    .fontSize(17).fontWeight(FontWeight.Bold).fontColor(Ui.textSecondary)
                  Text('在上方粘贴订阅链接开始使用')
                    .fontSize(13).fontColor(Ui.textTertiary)
                }
                .width('100%')
                .padding({ top: 54, bottom: 54 })
              } else {
                ForEach(this.subs, (sub: Subscription) => {
                  Column() {
                    Row({ space: 14 }) {
                      Column() {
                        Text('📡').fontSize(20).fontColor(Ui.primaryBlue)
                      }
                      .width(48).height(48)
                      .borderRadius(14)
                      .linearGradient({ angle: 135, colors: [['#1C315E', 0.0], ['#173D42', 1.0]] })
                      .justifyContent(FlexAlign.Center)

                      Column({ space: 4 }) {
                        Text(sub.name)
                          .fontSize(17).fontWeight(FontWeight.Bold)
                          .fontColor(Ui.textPrimary)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(this.maskedUrl(sub.url))
                          .fontSize(12).fontColor(Ui.textTertiary)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)

                      Text('✎')
                        .fontSize(18).fontColor(Ui.textSecondary)
                        .padding(6)
                        .onClick(() => this.openEdit(sub))
                      Text('🗑')
                        .fontSize(18).fontColor(Ui.error)
                        .padding(6)
                        .onClick(() => {
                          this.deleteTargetId = sub.id;
                          this.deleteDialog.open();
                        })
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)

                    Blank().height(14)
                    Row({ space: 7 }) {
                      Circle({ width: 8, height: 8 })
                        .fill(sub.enabled ? Ui.success : Ui.error)
                      Text(sub.enabled ? '已启用' : '已禁用')
                        .fontSize(12).fontColor(sub.enabled ? Ui.success : Ui.error)
                      Blank().width(11)
                      Text('🔗').fontSize(13)
                      Text(`${sub.nodeCount} 节点`)
                        .fontSize(12).fontColor(Ui.textSecondary)
                      Blank().width(11)
                      Text('🕒').fontSize(13)
                      Text(this.formatUpdateTime(sub.lastFetchedAt))
                        .fontSize(12).fontColor(Ui.textTertiary)
                        .maxLines(1)
                        .layoutWeight(1)
                    }
                    .width('100%')
                  }
                  .width('100%')
                  .padding(18)
                  .borderRadius(22)
                  .backgroundColor('#E0242641')
                  .borderWidth(1)
                  .borderColor(Ui.border)
                  .shadow({ radius: 28, color: '#38000000', offsetY: 14 })
                  .margin({ bottom: 12 })
                  .gesture(LongPressGesture().onAction(() => this.openEdit(sub)))
                }, (sub: Subscription) => `${sub.id}|${sub.name}|${sub.nodeCount}|${sub.lastFetchedAt}|${sub.enabled ? 1 : 0}`)
              }
            }
            .constraintSize({ maxWidth: Ui.pageMaxWidth })
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .padding({ left: 18, right: 18, top: 0, bottom: 130 })
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')

      // ── 浮动底部导航（与主页一致, 主页/订阅可互相切换, 无需返回键） ──
      this.BottomNav()
    }
    .width('100%').height('100%')
  }

  /** 浮动底部导航（对齐 SsrvpnBottomNavigation; 本页固定选中「订阅」） */
  @Builder
  BottomNav() {
    Column({ space: 6 }) {
      Row() {
        this.NavItem(false, '⌂', '主页', () => {
          // replaceUrl 切回主页, 避免路由栈堆叠
          router.replaceUrl({ url: 'pages/HomePage' });
        })
        this.NavItem(true, '☰', '订阅', () => {})
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
