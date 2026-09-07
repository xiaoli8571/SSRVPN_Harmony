/**
 * 数据模型：应用设置
 * 移植自 upstream: packages/ssrvpn_shared/lib/models/app_settings.dart
 * 字段与 upstream 保持一致；鸿蒙端持久化由 SettingsService（@ohos.data.preferences）承担。
 */

/** 持久化 JSON 形状（显式类，满足 arkts-no-untyped-obj-literals） */
export class AppSettingsJson {
  themeMode: number = 0;
  autoConnectOnBoot: boolean = true;
  bypassDomesticApps: boolean = true;
  excludedApps: string[] = [];
  forceProxySites: string[] = [];
  forceDirectSites: string[] = [];
  preferredNodeId: string = '';
  preferredNodeSubscriptionId: string = '';
  autoUpdateSubscription: boolean = true;
  selectedSubscriptionId: string = '';
  testLatencyUrl: string = 'https://www.gstatic.com/generate_204';
  proxyMode: string = 'rule';
}

export class AppSettings {
  /** 跟随系统 / 暗色 / 亮色 */
  themeMode: number = 0; // 0=system, 1=dark, 2=light
  autoConnectOnBoot: boolean = true;
  bypassDomesticApps: boolean = true;
  excludedApps: string[] = [];
  forceProxySites: string[] = [];
  /** 强制直连网站（始终 DIRECT, 不走代理） */
  forceDirectSites: string[] = [];
  preferredNodeId: string = '';
  preferredNodeSubscriptionId: string = '';
  autoUpdateSubscription: boolean = true;
  selectedSubscriptionId: string = '';
  testLatencyUrl: string = 'https://www.gstatic.com/generate_204';
  /** 代理模式：rule = 规则 / global = 全局（对应 upstream settings.proxyMode） */
  proxyMode: string = 'rule';

  toJson(): AppSettingsJson {
    const j = new AppSettingsJson();
    j.themeMode = this.themeMode;
    j.autoConnectOnBoot = this.autoConnectOnBoot;
    j.bypassDomesticApps = this.bypassDomesticApps;
    j.excludedApps = this.excludedApps;
    j.forceProxySites = this.forceProxySites;
    j.forceDirectSites = this.forceDirectSites;
    j.preferredNodeId = this.preferredNodeId;
    j.preferredNodeSubscriptionId = this.preferredNodeSubscriptionId;
    j.autoUpdateSubscription = this.autoUpdateSubscription;
    j.selectedSubscriptionId = this.selectedSubscriptionId;
    j.testLatencyUrl = this.testLatencyUrl;
    j.proxyMode = this.proxyMode;
    return j;
  }

  static fromJson(j: AppSettingsJson): AppSettings {
    const s = new AppSettings();
    s.themeMode = j.themeMode;
    s.autoConnectOnBoot = j.autoConnectOnBoot;
    s.bypassDomesticApps = j.bypassDomesticApps;
    s.excludedApps = j.excludedApps;
    s.forceProxySites = j.forceProxySites;
    // 兼容旧版本存档（无该字段时为 undefined, 兜底空数组）
    s.forceDirectSites = j.forceDirectSites !== undefined ? j.forceDirectSites : [];
    s.preferredNodeId = j.preferredNodeId;
    s.preferredNodeSubscriptionId = j.preferredNodeSubscriptionId;
    s.autoUpdateSubscription = j.autoUpdateSubscription;
    s.selectedSubscriptionId = j.selectedSubscriptionId;
    s.testLatencyUrl = j.testLatencyUrl;
    s.proxyMode = j.proxyMode;
    return s;
  }
}
