/**
 * 数据模型：订阅
 * 移植自 upstream: packages/ssrvpn_shared/lib/models/subscription.dart
 */
import { SubscriptionJson } from '../services/SubscriptionService';

export class Subscription {
  id: string = '';
  name: string = '';
  url: string = '';
  /** 自定义请求头名（UA 协商时用户可覆盖默认 UA），对应 upstream subscription_header_name_parser */
  headerName: string = '';
  /**
   * 自定义请求头值（等价于订阅鉴权 token）：敏感凭据，只允许写入 AssetStore。
   * 该字段从不参与 preferences JSON 序列化（Subscription.toJson 恒写空串），
   * 仅在内存中持有；进程重启后由 CredentialStore 从加密层回填。
   */
  headerValue: string = '';
  /** 上次成功拉取的原始内容缓存 key（源缓存） */
  lastFetchedAt: number = 0;
  lastRefreshResult: string = '';
  nodeCount: number = 0;
  uploadBytes: number = -1;
  downloadBytes: number = -1;
  totalBytes: number = -1;
  expireAt: number = -1;
  enabled: boolean = true;
  sortOrder: number = 0;

  static newSubscription(id: string, name: string, url: string): Subscription {
    const s = new Subscription();
    s.id = id;
    s.name = name;
    s.url = url;
    return s;
  }

  static toJson(s: Subscription): SubscriptionJson {
    const j = new SubscriptionJson();
    j.id = s.id;
    j.name = s.name;
    j.url = s.url;
    j.headerName = s.headerName;
    // headerValue 属敏感凭据：永不写 preferences（加密层由 SubscriptionService.persist 负责）
    j.headerValue = '';
    j.lastFetchedAt = s.lastFetchedAt;
    j.lastRefreshResult = s.lastRefreshResult;
    j.nodeCount = s.nodeCount;
    j.uploadBytes = s.uploadBytes;
    j.downloadBytes = s.downloadBytes;
    j.totalBytes = s.totalBytes;
    j.expireAt = s.expireAt;
    j.enabled = s.enabled;
    j.sortOrder = s.sortOrder;
    return j;
  }

  static fromPersistJson(j: SubscriptionJson): Subscription {
    const s = new Subscription();
    s.id = j.id;
    s.name = j.name;
    s.url = j.url;
    s.headerName = j.headerName;
    s.headerValue = j.headerValue;
    s.lastFetchedAt = j.lastFetchedAt;
    s.lastRefreshResult = j.lastRefreshResult;
    s.nodeCount = j.nodeCount;
    s.uploadBytes = j.uploadBytes ?? -1;
    s.downloadBytes = j.downloadBytes ?? -1;
    s.totalBytes = j.totalBytes ?? -1;
    s.expireAt = j.expireAt ?? -1;
    s.enabled = j.enabled;
    s.sortOrder = j.sortOrder;
    return s;
  }
}

export enum SubscriptionRefreshStatus {
  OK = 'ok',
  NOT_MODIFIED = 'notModified',
  NETWORK_ERROR = 'networkError',
  HTTP_ERROR = 'httpError',
  EMPTY_RESPONSE = 'emptyResponse',
  DECODE_ERROR = 'decodeError',
  PARSE_ERROR = 'parseError',
  LIMIT_EXCEEDED = 'limitExceeded',
  PERSIST_ERROR = 'persistError'
}

/** 三种导入入口共用的诊断统计，所有跳过原因均显式可见。 */
export class SubscriptionImportDiagnostics {
  inputCount: number = 0;
  addedCount: number = 0;
  duplicateCount: number = 0;
  invalidCount: number = 0;
  unsupportedCount: number = 0;
  hiddenCount: number = 0;
  limitCount: number = 0;
  unsupportedTypes: string = '';

  skippedCount(): number {
    return this.duplicateCount + this.invalidCount + this.unsupportedCount
      + this.hiddenCount + this.limitCount;
  }

  summary(): string {
    const details: string[] = [];
    if (this.duplicateCount > 0) {
      details.push(`重复 ${this.duplicateCount}`);
    }
    if (this.invalidCount > 0) {
      details.push(`无效 ${this.invalidCount}`);
    }
    if (this.unsupportedCount > 0) {
      const types = this.unsupportedTypes.length > 0 ? `（${this.unsupportedTypes}）` : '';
      details.push(`不支持 ${this.unsupportedCount}${types}`);
    }
    if (this.hiddenCount > 0) {
      details.push(`已隐藏 ${this.hiddenCount}`);
    }
    if (this.limitCount > 0) {
      details.push(`超限 ${this.limitCount}`);
    }
    const skipped = this.skippedCount();
    return `成功 ${this.addedCount}，跳过 ${skipped}`
      + (details.length > 0 ? `（${details.join('，')}）` : '');
  }
}

/** 刷新结果分类，移植自 subscription_refresh_result.dart */
export class SubscriptionRefreshResult {
  status: SubscriptionRefreshStatus = SubscriptionRefreshStatus.OK;
  message: string = '';
  nodeCount: number = 0;
  diagnostics: SubscriptionImportDiagnostics = new SubscriptionImportDiagnostics();

  static ok(nodeCount: number, diagnostics?: SubscriptionImportDiagnostics): SubscriptionRefreshResult {
    const r = new SubscriptionRefreshResult();
    r.status = SubscriptionRefreshStatus.OK;
    r.nodeCount = nodeCount;
    if (diagnostics !== undefined) {
      r.diagnostics = diagnostics;
    } else {
      r.diagnostics.addedCount = nodeCount;
    }
    return r;
  }

  static fail(status: SubscriptionRefreshStatus, message: string,
    diagnostics?: SubscriptionImportDiagnostics): SubscriptionRefreshResult {
    const r = new SubscriptionRefreshResult();
    r.status = status;
    r.message = message;
    if (diagnostics !== undefined) {
      r.diagnostics = diagnostics;
    }
    return r;
  }
}
