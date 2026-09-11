/**
 * Clash RESTful API 客户端
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/clash_service_base.dart
 *                clash_service_latency_support.dart
 *                clash_service_data_plane_support.dart
 * 对应 Android 端 MihomoApiWaiter / MihomoApiHealthProbe / MihomoProxySelection 的职责。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'ClashApiService';

export interface LatencyResult {
  nodeName: string;
  delayMs: number; // -1 = 超时/失败
}

export interface TrafficSnapshot {
  uploadBytes: number;
  downloadBytes: number;
  uploadSpeed: number;
  downloadSpeed: number;
}

export class ClashApiService {
  private apiPort: number = 9090;
  private secret: string = '';

  /**
   * 在途延迟测试请求集合。
   * 批量测速会同时挂起 N 路 /proxies/{name}/delay；页面退出或新批次开始时若只靠
   * 逻辑标志位，内核侧这些出站连接仍会跑到各自超时（最长 2.5~5s）继续占用通道，
   * 表现为「旧批次和新批次抢通道、整体变慢」。cancelInflight() 直接 destroy 掉
   * 在途请求，通道立刻释放。
   */
  private inflight: Set<http.HttpRequest> = new Set<http.HttpRequest>();

  /** 中断所有在途延迟测试请求，返回被中断的数量（其余业务请求不受影响）。 */
  cancelInflight(): number {
    const n = this.inflight.size;
    for (const req of this.inflight) {
      try {
        req.destroy();
      } catch (e) {
        // 已结束的请求 destroy 抛错属正常
      }
    }
    this.inflight.clear();
    return n;
  }

  setEndpoint(port: number, secret: string): void {
    this.apiPort = port;
    this.secret = secret;
  }

  private baseUrl(): string {
    return `http://127.0.0.1:${this.apiPort}`;
  }

  private authHeader(): Record<string, string> {
    const h: Record<string, string> = {};
    if (this.secret.length > 0) {
      h['Authorization'] = `Bearer ${this.secret}`;
    }
    return h;
  }

  private errText(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return String(e);
  }

  /** 等待 API 就绪（对应 MihomoApiWaiter），超时返回 false */
  async waitReady(timeoutMs: number, intervalMs: number = 300): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await this.healthProbe()) {
        return true;
      }
      await ClashApiService.sleep(intervalMs);
    }
    return false;
  }

  /** 健康探测（对应 MihomoApiHealthProbe）：GET /version */
  async healthProbe(): Promise<boolean> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/version`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 1500,
        readTimeout: 1500,
        usingCache: false
      });
      return resp.responseCode === 200;
    } catch (e) {
      return false;
    } finally {
      req.destroy();
    }
  }

  /** 切换选中节点。必须同时下发到 PROXY 组和 GLOBAL 组:
   *  mihomo 在 global(全局)模式下忽略具名 PROXY 组, 走隐式 GLOBAL 组; 若不设置
   *  GLOBAL, 它默认选 DIRECT → 全局模式下所有流量直连、被国内 DNS 污染打不开。
   *  (真机实证: 全局模式 GLOBAL now=DIRECT, youtube dial 假 IP 超时。) */
  async selectNode(nodeName: string): Promise<boolean> {
    const okProxy = await this.selectInGroup('PROXY', nodeName);
    const okGlobal = await this.selectInGroup('GLOBAL', nodeName);
    return okProxy || okGlobal;
  }

  /** 在指定代理组选择节点: PUT /proxies/{group} {name} */
  private async selectInGroup(group: string, nodeName: string): Promise<boolean> {
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = this.authHeader();
      headers['Content-Type'] = 'application/json';
      const payload: Record<string, string> = {};
      payload['name'] = nodeName;
      const resp = await req.request(`${this.baseUrl()}/proxies/${encodeURIComponent(group)}`, {
        method: http.RequestMethod.PUT,
        header: headers,
        extraData: JSON.stringify(payload),
        connectTimeout: 3000,
        readTimeout: 3000,
        usingCache: false
      });
      return resp.responseCode === 204 || resp.responseCode === 200;
    } catch (e) {
      AppLogger.error(TAG, `selectInGroup(${group}) failed: ${this.errText(e)}`);
      return false;
    } finally {
      req.destroy();
    }
  }

  /** 切换运行时代理模式（全局/规则）：PUT /configs（mihomo 中 PUT 与 PATCH 同为 updateConfigs） */
  async setMode(mode: string): Promise<boolean> {
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = this.authHeader();
      headers['Content-Type'] = 'application/json';
      const payload: Record<string, string> = {};
      payload['mode'] = mode === 'global' ? 'global' : 'rule';
      const resp = await req.request(`${this.baseUrl()}/configs`, {
        method: http.RequestMethod.PUT,
        header: headers,
        extraData: JSON.stringify(payload),
        connectTimeout: 3000,
        readTimeout: 3000,
        usingCache: false
      });
      return resp.responseCode === 204 || resp.responseCode === 200;
    } catch (e) {
      AppLogger.error(TAG, `setMode failed: ${e instanceof Error ? e.message : String(e)}`);
      return false;
    } finally {
      req.destroy();
    }
  }

  /** 延迟测试（对应 clash_service_latency_support）：GET /proxies/{name}/delay */
  async testLatency(nodeName: string, testUrl: string, timeoutMs: number = 5000): Promise<number> {
    const req = http.createHttp();
    this.inflight.add(req);
    try {
      const outerTimeoutMs = timeoutMs + 2000;
      const startedAt = Date.now();
      const resp = await req.request(
        `${this.baseUrl()}/proxies/${encodeURIComponent(nodeName)}/delay?url=${encodeURIComponent(testUrl)}&timeout=${timeoutMs}`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: outerTimeoutMs,
        readTimeout: outerTimeoutMs,
        usingCache: false
      });
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (resp.responseCode !== 200) {
        AppLogger.warn(TAG, `latency non-200: code=${resp.responseCode} bodyLen=${body.length} `
          + `innerTimeout=${timeoutMs} outerTimeout=${outerTimeoutMs} elapsed=${Date.now() - startedAt}ms`);
        return -1;
      }
      if (body.length === 0) {
        AppLogger.warn(TAG, `latency empty response: innerTimeout=${timeoutMs} outerTimeout=${outerTimeoutMs} `
          + `elapsed=${Date.now() - startedAt}ms`);
        return -1;
      }
      try {
        const json = JSON.parse(body) as Record<string, number>;
        const delay = json['delay'];
        if (delay !== undefined) {
          return delay;
        }
        AppLogger.warn(TAG, `latency response missing delay: bodyLen=${body.length} `
          + `elapsed=${Date.now() - startedAt}ms`);
      } catch (jsonError) {
        AppLogger.warn(TAG, `latency JSON error: bodyLen=${body.length} error=${this.errText(jsonError)} `
          + `elapsed=${Date.now() - startedAt}ms`);
      }
      return -1;
    } catch (e) {
      AppLogger.warn(TAG, `latency request error: innerTimeout=${timeoutMs} outerTimeout=${timeoutMs + 2000} `
        + `error=${this.errText(e)}`);
      return -1;
    } finally {
      this.inflight.delete(req);
      req.destroy();
    }
  }

  /** 流量快照：GET /connections。
   *  mihomo 的 Snapshot 只有 uploadTotal/downloadTotal(累计字节), 没有速率字段;
   *  速率由本类按两次轮询的总量差值计算(比另开 /traffic WebSocket 更省资源)。 */
  private lastDownloadTotal: number = -1;
  private lastUploadTotal: number = -1;
  private lastPollAt: number = 0;

  /** 清空差值基线（连接/断开时调用, 避免跨会话算出假速率） */
  resetTrafficBaseline(): void {
    this.lastUploadTotal = -1;
    this.lastDownloadTotal = -1;
    this.lastPollAt = 0;
    this.trafficLogged = 0;
  }

  /** 一次性诊断: 前 3 次轮询把响应概况写入运行日志(排查面板恒 0 问题) */
  private trafficLogged: number = 0;

  private logTrafficOnce(code: number, bodyLen: number, up: number, down: number): void {
    if (this.trafficLogged < 3) {
      this.trafficLogged = this.trafficLogged + 1;
      AppLogger.info(TAG, `traffic diag: code=${code} len=${bodyLen} up=${up} down=${down}`);
    }
  }

  async traffic(): Promise<TrafficSnapshot> {
    const empty: TrafficSnapshot = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/connections`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 2000,
        readTimeout: 2000,
        usingCache: false
      });
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (resp.responseCode !== 200 || body.length === 0) {
        return empty;
      }
      const json = JSON.parse(body) as Record<string, number>;
      const uploadBytes = json['uploadTotal'] !== undefined ? json['uploadTotal'] : 0;
      const downloadBytes = json['downloadTotal'] !== undefined ? json['downloadTotal'] : 0;
      this.logTrafficOnce(resp.responseCode, body.length, uploadBytes, downloadBytes);
      const now = Date.now();
      let uploadSpeed = 0;
      let downloadSpeed = 0;
      if (this.lastPollAt > 0 && now > this.lastPollAt && this.lastUploadTotal >= 0) {
        const elapsedSeconds = (now - this.lastPollAt) / 1000;
        const du = uploadBytes - this.lastUploadTotal;
        const dd = downloadBytes - this.lastDownloadTotal;
        if (du >= 0) {
          uploadSpeed = du / elapsedSeconds;
        }
        if (dd >= 0) {
          downloadSpeed = dd / elapsedSeconds;
        }
      }
      this.lastUploadTotal = uploadBytes;
      this.lastDownloadTotal = downloadBytes;
      this.lastPollAt = now;
      const result: TrafficSnapshot = {
        uploadBytes: uploadBytes,
        downloadBytes: downloadBytes,
        uploadSpeed: uploadSpeed,
        downloadSpeed: downloadSpeed
      };
      return result;
    } catch (e) {
      if (this.trafficLogged < 3) {
        this.trafficLogged = this.trafficLogged + 1;
        AppLogger.info(TAG, `traffic diag: request failed ${e instanceof Error ? e.message : String(e)}`);
      }
      return empty;
    } finally {
      req.destroy();
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => resolve(), ms);
    });
  }
}
