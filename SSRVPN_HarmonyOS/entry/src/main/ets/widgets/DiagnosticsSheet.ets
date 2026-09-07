/**
 * 诊断面板（底部弹出）
 * 移植自 upstream: SSRVPN_Android/lib/widgets/android_diagnostics_sheet.dart
 *                packages/ssrvpn_shared/lib/widgets/app_diagnostics_view.dart
 */
import { AppTheme, Palette } from '../theme/AppTheme';
import { AppDiagnostics } from '../commons/models/PublicIpInfo';
import { AppLogger } from '../commons/utils/AppLogger';

@Component
export struct DiagnosticsSheet {
  @Prop darkMode: boolean = true;
  @Prop diag: AppDiagnostics | null = null;
  onRefresh: () => void = () => {};
  onClose: () => void = () => {};

  private pal(): Palette {
    return AppTheme.isDark(this.darkMode);
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('诊断信息')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.pal().textPrimary)
        Blank()
        Text('刷新')
          .fontSize(14)
          .fontColor(AppTheme.primaryColor)
          .onClick(() => this.onRefresh())
        Text('关闭')
          .fontSize(14)
          .fontColor(this.pal().textSecondary)
          .onClick(() => this.onClose())
          .padding({ left: 16 })
      }
      .width('100%')

      Row() {
        Text('内核运行').fontSize(14).fontColor(this.pal().textSecondary).layoutWeight(1)
        Text(this.coreRunningText()).fontSize(14).fontColor(this.coreRunningColor())
      }.width('100%')

      Row() {
        Text('VPN 激活').fontSize(14).fontColor(this.pal().textSecondary).layoutWeight(1)
        Text(this.vpnActiveText()).fontSize(14).fontColor(this.vpnActiveColor())
      }.width('100%')

      Row() {
        Text('Clash API').fontSize(14).fontColor(this.pal().textSecondary).layoutWeight(1)
        Text(this.apiText()).fontSize(14).fontColor(this.apiColor())
      }.width('100%')

      Row() {
        Text('运行时长').fontSize(14).fontColor(this.pal().textSecondary).layoutWeight(1)
        Text(this.uptimeText()).fontSize(14).fontColor(this.pal().textPrimary)
      }.width('100%')

      if (this.hasLastError()) {
        Text(`最近错误: ${this.lastErrorText()}`)
          .fontSize(13)
          .fontColor(AppTheme.errorColor)
          .width('100%')
      }

      Divider().color(this.pal().border)

      Text('运行日志')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().textPrimary)

      List() {
        ForEach(AppLogger.dump(), (line: string) => {
          ListItem() {
            Text(line)
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor(this.pal().textSecondary)
              .width('100%')
              .padding({ top: 1, bottom: 1 })
          }
        }, (line: string, idx: number) => `${idx}-${line.length}`)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .padding(20)
    .backgroundColor(this.pal().surface)
    .borderRadius({ topLeft: 20, topRight: 20 })
  }

  private coreRunningText(): string {
    return this.diag !== null && this.diag.coreRunning ? '正常' : '未运行';
  }

  private coreRunningColor(): string {
    return this.diag !== null && this.diag.coreRunning ? AppTheme.successColor : AppTheme.errorColor;
  }

  private vpnActiveText(): string {
    return this.diag !== null && this.diag.vpnActive ? '已激活' : '未激活';
  }

  private vpnActiveColor(): string {
    return this.diag !== null && this.diag.vpnActive ? AppTheme.successColor : AppTheme.warningColor;
  }

  private apiText(): string {
    if (this.diag !== null && this.diag.clashApiReachable) {
      return `可达 :${this.diag.clashApiPort}`;
    }
    return '不可达';
  }

  private apiColor(): string {
    return this.diag !== null && this.diag.clashApiReachable ? AppTheme.successColor : AppTheme.errorColor;
  }

  private uptimeText(): string {
    const d = this.diag;
    const up = d !== null ? d.uptimeSeconds : 0;
    return `${up}s`;
  }

  private hasLastError(): boolean {
    return this.diag !== null && this.diag.lastError.length > 0;
  }

  private lastErrorText(): string {
    const d = this.diag;
    return d !== null ? d.lastError : '';
  }
}
