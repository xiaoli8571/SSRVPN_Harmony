/**
 * 订阅拉取策略：UA 协商
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/subscription_fetch_policy.dart
 *
 * UA 顺序（必须一致）：SSRVPN → Clash Verge → v2rayN → Shadowrocket。
 * 每次降级重试都在 HTTP 403/406 或空结果时触发。
 */
import { http } from '@kit.NetworkKit';
import { url, util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'SubscriptionFetchPolicy';

/**
 * UA 顺序：优先 Clash 系 UA 让面板直接返回 Clash YAML（vmess/vless/trojan 字段最完整），
 * 其余 UA 依次兜底；解析层同时支持 vless/vmess/trojan 链接格式。
 */
export const UA_CHAIN: string[] = [
  'clash-verge/v1.7.7',
  'clash.meta/v1.18.8',
  'SSRVPN/4.0.28',
  'v2rayN/6.23',
  'Shadowrocket/2077'
];

export class SubscriptionFetchPolicy {
  /** 依次尝试 UA 链，返回第一个非空响应体。 */
  static async fetch(urlStr: string, headerName: string, headerValue: string): Promise<string> {
    const customHeader = headerName.length > 0 && headerValue.length > 0;
    const attempts: string[] = [];
    for (let i = 0; i < UA_CHAIN.length; i++) {
      const ua = customHeader ? headerValue : UA_CHAIN[i];
      try {
        const req = http.createHttp();
        const headers: Record<string, string> = {};
        if (customHeader) {
          headers[headerName] = ua;
        } else {
          headers['User-Agent'] = ua;
        }
        const resp = await req.request(urlStr, {
          method: http.RequestMethod.GET,
          header: headers,
          connectTimeout: 15000,
          readTimeout: 20000,
          usingCache: false
        });
        const code = resp.responseCode;
        if (code !== 200) {
          AppLogger.warn(TAG, `HTTP ${code} with UA "${ua}" for ${SubscriptionFetchPolicy.redactUrl(urlStr)}`);
          attempts.push(`HTTP ${code}`);
          req.destroy();
          continue;
        }
        let body: string = '';
        if (typeof resp.result === 'string') {
          body = resp.result as string;
        } else if (resp.result instanceof ArrayBuffer) {
          body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
        }
        req.destroy();
        body = body.trim();
        if (body.length > 0) {
          AppLogger.info(TAG, `fetched via UA "${ua}" (${body.length} bytes)`);
          return body;
        }
        attempts.push('响应为空');
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        AppLogger.warn(TAG, `fetch error with UA "${ua}": ${msg}`);
        attempts.push(msg);
      }
    }
    throw new Error(`订阅拉取失败（${SubscriptionFetchPolicy.redactUrl(urlStr)}）：${attempts.slice(0, 2).join(' / ')}`);
  }

  /** URL 脱敏（只保留 host），配合 log_redactor */
  static redactUrl(urlStr: string): string {
    try {
      return url.URL.parseURL(urlStr).host;
    } catch (e) {
      return '<invalid-url>';
    }
  }

  /** 订阅 URL 合法性（对应 subscription_url_policy.dart） */
  static isValidSubscriptionUrl(urlStr: string): boolean {
    if (urlStr.length === 0) {
      return false;
    }
    if (!urlStr.startsWith('https://') && !urlStr.startsWith('http://')) {
      return false;
    }
    try {
      const parsed = url.URL.parseURL(urlStr);
      const proto = parsed.protocol.replace(/:/g, '');
      return proto === 'https' || proto === 'http';
    } catch (e) {
      return false;
    }
  }
}
