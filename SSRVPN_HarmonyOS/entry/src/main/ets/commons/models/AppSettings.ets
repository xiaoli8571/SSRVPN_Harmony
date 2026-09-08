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
    s.themeMode = j.themeMode === 1 || j.themeMode === 2 ? j.themeMode : 0;
    s.autoConnectOnBoot = typeof j.autoConnectOnBoot === 'boolean' ? j.autoConnectOnBoot : true;
    s.bypassDomesticApps = typeof j.bypassDomesticApps === 'boolean' ? j.bypassDomesticApps : true;
    s.excludedApps = Array.isArray(j.excludedApps)
      ? j.excludedApps.filter((v: string) => typeof v === 'string') : [];
    s.forceProxySites = Array.isArray(j.forceProxySites)
      ? j.forceProxySites.filter((v: string) => typeof v === 'string') : [];
    s.forceDirectSites = Array.isArray(j.forceDirectSites)
      ? j.forceDirectSites.filter((v: string) => typeof v === 'string') : [];
    s.preferredNodeId = typeof j.preferredNodeId === 'string' ? j.preferredNodeId : '';
    s.preferredNodeSubscriptionId = typeof j.preferredNodeSubscriptionId === 'string'
      ? j.preferredNodeSubscriptionId : '';
    s.autoUpdateSubscription = typeof j.autoUpdateSubscription === 'boolean' ? j.autoUpdateSubscription : true;
    s.selectedSubscriptionId = typeof j.selectedSubscriptionId === 'string' ? j.selectedSubscriptionId : '';
    s.testLatencyUrl = typeof j.testLatencyUrl === 'string' && j.testLatencyUrl.length > 0
      ? j.testLatencyUrl : 'https://www.gstatic.com/generate_204';
    s.proxyMode = j.proxyMode === 'global' ? 'global' : 'rule';
    return s;
  }
}
