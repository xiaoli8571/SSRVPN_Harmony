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
    try {
      const resp = await req.request(
        `${this.baseUrl()}/proxies/${encodeURIComponent(nodeName)}/delay?url=${encodeURIComponent(testUrl)}&timeout=${timeoutMs}`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        usingCache: false
      });
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (resp.responseCode === 200 && body.length > 0) {
        const json = JSON.parse(body) as Record<string, number>;
        const delay = json['delay'];
        return delay !== undefined ? delay : -1;
      }
      return -1;
    } catch (e) {
      return -1;
    } finally {
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
