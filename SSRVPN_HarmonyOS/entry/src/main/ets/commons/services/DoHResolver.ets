/**
 * DoH 解析器（UI 进程）—— 代理服务器域名的防投毒解析。
 *
 * 背景: 明文 UDP DNS 会被 GFW 按域名投毒(真机实测: 代理服务器域名被注入 Facebook
 * 段 IP, 内核拨假地址全线 i/o timeout, 表现为"连上了但 YouTube 等全部打不开")。
 * DoH 是 HTTPS 加密查询, 注入无法篡改; doh.pub / dns.alidns.com 国内直连可达。
 *
 * 必须在 UI 进程、VPN 隧道建立之前调用(此时网络干净)。解析结果写进 YAML 的
 * hosts: 段, 内核直接用真实 IP 拨号代理服务器, 彻底绕开运行期被污染的 DNS。
 */
import { http } from '@kit.NetworkKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'DoHResolver';
const ENDPOINTS: string[] = ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query'];

/** DoH JSON 应答结构(只取需要的字段) */
interface DoHAnswer {
  name: string;
  type: number;
  data: string;
}

interface DoHResponse {
  Status: number;
  Answer?: DoHAnswer[];
}

export class DoHResolver {
  /** 跨连接缓存: domain -> ip, 避免每次连接重复解析 */
  private static cache: Map<string, string> = new Map<string, string>();

  /**
   * 批量解析多个域名(去重后), 带全局时间预算, 超时未解析的域名跳过(内核回退
   * proxy-server-nameserver)。返回 domain->ip 映射(仅含解析成功的)。
   */
  static async resolveMany(domains: string[], budgetMs: number = 5000): Promise<Record<string, string>> {
    const result: Record<string, string> = {};
    const pending: string[] = [];
    for (const d of domains) {
      const cached = DoHResolver.cache.get(d);
      if (cached !== undefined && cached.length > 0) {
        result[d] = cached;
      } else {
        pending.push(d);
      }
    }
    if (pending.length === 0) {
      return result;
    }
    const deadline = Date.now() + budgetMs;
    // 并发 8
    const workers: Promise<void>[] = [];
    let idx = 0;
    for (let w = 0; w < 8; w++) {
      workers.push((async (): Promise<void> => {
        while (idx < pending.length) {
          if (Date.now() > deadline) {
            return;
          }
          const d = pending[idx];
          idx = idx + 1;
          const ip = await DoHResolver.resolveA(d);
          if (ip.length > 0) {
            DoHResolver.cache.set(d, ip);
            result[d] = ip;
          }
        }
      })());
    }
    await Promise.all(workers);
    return result;
  }

  /** 解析单个域名的 A 记录; 失败返回空串(调用方回退到 proxy-server-nameserver) */
  static async resolveA(domain: string): Promise<string> {
    const cached = DoHResolver.cache.get(domain);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    for (const ep of ENDPOINTS) {
      const req = http.createHttp();
      try {
        const queryUrl = ep + '?name=' + encodeURIComponent(domain) + '&type=A';
        const resp = await req.request(queryUrl, {
          method: http.RequestMethod.GET,
          header: {
            'Accept': 'application/dns-json',
            'User-Agent': 'Mozilla/5.0'
          } as Record<string, string>,
          connectTimeout: 2500,
          readTimeout: 2500,
          expectDataType: http.HttpDataType.STRING,
          usingCache: false
        } as http.HttpRequestOptions);
        const code = resp.responseCode;
        let body = '';
        if (typeof resp.result === 'string') {
          body = resp.result as string;
        }
        if (code !== 200 || body.length === 0) {
          continue;
        }
        const parsed = JSON.parse(body) as DoHResponse;
        if (parsed.Status !== 0 || parsed.Answer === undefined) {
          continue;
        }
        for (const a of parsed.Answer) {
          // type 1 = A; data 是 IPv4 点分十进制
          if (a.type === 1 && DoHResolver.looksLikeIPv4(a.data)) {
            DoHResolver.cache.set(domain, a.data);
            return a.data;
          }
        }
      } catch (e) {
        AppLogger.info(TAG, `DoH ${ep} for ${domain} failed: ${e instanceof Error ? e.message : String(e)}`);
      } finally {
        req.destroy();
      }
    }
    return '';
  }

  private static looksLikeIPv4(s: string): boolean {
    const parts = s.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const p of parts) {
      const n = Number(p);
      if (Number.isNaN(n) || n < 0 || n > 255 || `${n}` !== p) {
        return false;
      }
    }
    return true;
  }
}
