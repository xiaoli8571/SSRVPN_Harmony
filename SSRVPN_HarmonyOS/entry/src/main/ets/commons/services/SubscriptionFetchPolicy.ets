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
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(urlStr)) {
      throw new Error('订阅地址无效：仅允许公开 HTTPS 地址');
    }
    const customHeader = headerName.length > 0 && headerValue.length > 0;
    const attempts: string[] = [];
    for (let i = 0; i < UA_CHAIN.length; i++) {
      const ua = customHeader ? headerValue : UA_CHAIN[i];
      const req = http.createHttp();
      try {
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
          continue;
        }
        let body: string = '';
        if (typeof resp.result === 'string') {
          body = resp.result as string;
        } else if (resp.result instanceof ArrayBuffer) {
          body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
        }
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
      } finally {
        req.destroy();
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

  /** 订阅 URL 合法性：仅允许公开 HTTPS 地址，阻止明文传输和常见 SSRF 目标。 */
  static isValidSubscriptionUrl(urlStr: string): boolean {
    if (urlStr.length === 0 || urlStr.length > 8192 || !urlStr.toLowerCase().startsWith('https://')
      || urlStr.includes('\n') || urlStr.includes('\r') || urlStr.includes('\t')) {
      return false;
    }
    try {
      const parsed = url.URL.parseURL(urlStr);
      const proto = parsed.protocol.replace(/:/g, '').toLowerCase();
      let authority = parsed.host.toLowerCase();
      if (proto !== 'https' || authority.length === 0 || authority.includes('@')) {
        return false;
      }

      let host = authority;
      let port = '';
      if (authority.startsWith('[')) {
        const close = authority.indexOf(']');
        if (close <= 1) {
          return false;
        }
        host = authority.substring(1, close);
        const suffix = authority.substring(close + 1);
        if (suffix.length > 0) {
          if (!suffix.startsWith(':')) {
            return false;
          }
          port = suffix.substring(1);
        }
      } else {
        const colon = authority.lastIndexOf(':');
        if (colon >= 0) {
          if (authority.indexOf(':') !== colon) {
            return false;
          }
          host = authority.substring(0, colon);
          port = authority.substring(colon + 1);
        }
      }
      if (host.length === 0 || (port.length > 0 && port !== '443')) {
        return false;
      }

      if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')
        || host === 'localhost.localdomain' || host === 'ip6-localhost' || host === 'ip6-loopback'
        || host.endsWith('.internal') || host.endsWith('.home') || host.endsWith('.lan')) {
        return false;
      }

      const ipv4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
      if (ipv4 !== null) {
        const a = Number(ipv4[1]);
        const b = Number(ipv4[2]);
        const c = Number(ipv4[3]);
        const d = Number(ipv4[4]);
        if (a > 255 || b > 255 || c > 255 || d > 255) {
          return false;
        }
        if (a === 0 || a === 10 || a === 127 || a >= 224
          || (a === 100 && b >= 64 && b <= 127)
          || (a === 169 && b === 254)
          || (a === 172 && b >= 16 && b <= 31)
          || (a === 192 && b === 0 && (c === 0 || c === 2))
          || (a === 192 && b === 168)
          || (a === 198 && (b === 18 || b === 19))
          || (a === 198 && b === 51 && c === 100)
          || (a === 203 && b === 0 && c === 113)) {
          return false;
        }
        return true;
      }

      if (host.includes(':')) {
        const normalized = host.toLowerCase();
        if (!/^[0-9a-f:]+$/.test(normalized) || normalized.includes('%')) {
          return false;
        }
        return !(normalized === '::' || normalized === '::1' || normalized.startsWith('fc')
          || normalized.startsWith('fd') || normalized.startsWith('fe8')
          || normalized.startsWith('fe9') || normalized.startsWith('fea')
          || normalized.startsWith('feb') || normalized.startsWith('ff')
          || normalized.startsWith('2001:db8:'));
      }

      if (host.length > 253 || host.startsWith('.') || host.endsWith('.') || host.includes('..')) {
        return false;
      }
      const labels = host.split('.');
      if (labels.length < 2) {
        return false;
      }
      for (const label of labels) {
        if (label.length === 0 || label.length > 63 || label.startsWith('-') || label.endsWith('-')
          || !/^[a-z0-9-]+$/.test(label)) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }
}
