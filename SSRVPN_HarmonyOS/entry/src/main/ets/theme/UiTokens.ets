/**
 * SSRVPN UI Tokens — 1:1 对齐 upstream packages/ssrvpn_shared/lib/widgets/ssrvpn_app_surface.dart
 * 这是真实安卓版使用的现代色板（app_theme.dart 为旧版兼容色，勿再使用）。
 */

/** 设计令牌（值逐项照抄 upstream SsrvpnUiTokens） */
export class Ui {
  static readonly background: string = '#0A1020';
  static readonly backgroundRaised: string = '#14152F';
  static readonly surface: string = '#242641';
  static readonly surfaceStrong: string = '#2C2E4B';
  static readonly primary: string = '#8A84FF';
  static readonly primaryBlue: string = '#3675FF';
  static readonly accent: string = '#20C8B4';
  static readonly success: string = '#29C978';
  static readonly warning: string = '#F3B83F';
  static readonly error: string = '#E35D6A';
  static readonly textPrimary: string = '#F5F7FF';
  static readonly textSecondary: string = '#A7AFC2';
  static readonly textTertiary: string = '#929BB1';
  static readonly border: string = '#33FFFFFF';

  static readonly pagePadding: number = 20;
  static readonly cardRadius: number = 24;
  static readonly compactBreakpoint: number = 460;
  static readonly pageMaxWidth: number = 440;
  static readonly bottomNavMaxWidth: number = 380;
  static readonly currentNodeMaxWidth: number = 320;

  /** 背景渐变（SsrvpnAppBackdrop：左上→右下三段） */
  static readonly backdropColors: Array<[string, number]> = [
    ['#181B3B', 0.0], ['#0A1020', 0.48], ['#09152A', 1.0]
  ];
}

/** 延迟配色与文案（对齐 ssrvpn_node_selection_node_card / current_node_card 阈值） */
export class LatencyStyle {
  static readonly TIMEOUT_MS: number = 65535;

  static isTimeout(latency: number | null): boolean {
    return latency !== null && (latency <= 0 || latency >= LatencyStyle.TIMEOUT_MS);
  }

  static color(latency: number | null): string {
    if (latency === null) {
      return Ui.textSecondary;
    }
    if (LatencyStyle.isTimeout(latency)) {
      return Ui.error;
    }
    if (latency < 180) {
      return Ui.success;
    }
    if (latency < 350) {
      return Ui.warning;
    }
    return Ui.error;
  }

  static text(latency: number | null): string {
    if (latency === null) {
      return '--';
    }
    if (LatencyStyle.isTimeout(latency)) {
      return '超时';
    }
    return `${latency}ms`;
  }
}

/** 节点显示规整（对齐 node_display_policy.dart） */
export class NodeDisplay {
  /** 去掉开头的国旗 emoji（upstream nodeDisplayNameWithoutLeadingFlag） */
  static withoutLeadingFlag(name: string): string {
    let out = name;
    // 移除开头的 regional-indicator emoji 对与其余前导旗帜符号
    while (out.length > 0) {
      const cp = out.codePointAt(0);
      if (cp === undefined) {
        break;
      }
      const isFlag = (cp >= 0x1F1E6 && cp <= 0x1F1FF) || cp === 0x1F3F3 || cp === 0xFE0F || cp === 0x200D;
      if (!isFlag) {
        break;
      }
      out = out.substring(String.fromCodePoint(cp).length);
    }
    return out.trimStart();
  }

  /** 截断过长的节点名（upstream compactNodeDisplayName：约 24 字符 + …） */
  static compact(name: string): string {
    if (name.length <= 24) {
      return name;
    }
    return `${name.substring(0, 23)}…`;
  }
}
