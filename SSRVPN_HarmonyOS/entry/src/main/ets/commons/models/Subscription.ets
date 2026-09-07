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
  headerValue: string = '';
  /** 上次成功拉取的原始内容缓存 key（源缓存） */
  lastFetchedAt: number = 0;
  lastRefreshResult: string = '';
  nodeCount: number = 0;
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
    j.headerValue = s.headerValue;
    j.lastFetchedAt = s.lastFetchedAt;
    j.lastRefreshResult = s.lastRefreshResult;
    j.nodeCount = s.nodeCount;
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
    s.enabled = j.enabled;
    s.sortOrder = j.sortOrder;
    return s;
  }
}

export enum SubscriptionRefreshStatus {
  OK = 'ok',
  NOT_MODIFIED = 'notModified',
  NETWORK_ERROR = 'networkError',
  PARSE_ERROR = 'parseError',
  HTTP_ERROR = 'httpError'
}

/** 刷新结果分类，移植自 subscription_refresh_result.dart */
export class SubscriptionRefreshResult {
  status: SubscriptionRefreshStatus = SubscriptionRefreshStatus.OK;
  message: string = '';
  nodeCount: number = 0;

  static ok(nodeCount: number): SubscriptionRefreshResult {
    const r = new SubscriptionRefreshResult();
    r.status = SubscriptionRefreshStatus.OK;
    r.nodeCount = nodeCount;
    return r;
  }

  static fail(status: SubscriptionRefreshStatus, message: string): SubscriptionRefreshResult {
    const r = new SubscriptionRefreshResult();
    r.status = status;
    r.message = message;
    return r;
  }
}
