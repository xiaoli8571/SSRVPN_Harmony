/**
 * 更新检查（对应 upstream update_checker.dart）
 * 查询 GitHub 最新 release 的 tag_name 并与当前版本比较。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

const CURRENT_VERSION = '4.0.28';
const RELEASES_API = 'https://api.github.com/repos/Elegying/SSRVPN/releases/latest';

export class UpdateChecker {
  /** 返回最新版本号；无更新或网络失败返回 '' */
  static async latestVersion(): Promise<string> {
    try {
      const req = http.createHttp();
      const headers: Record<string, string> = {};
      headers['User-Agent'] = 'SSRVPN-HarmonyOS';
      const resp = await req.request(RELEASES_API, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000,
        usingCache: false
      });
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      req.destroy();
      if (resp.responseCode !== 200 || body.length === 0) {
        return '';
      }
      const json = JSON.parse(body) as Record<string, Object>;
      const tag = json['tag_name'] as string;
      return tag !== undefined ? UpdateChecker.normalize(tag) : '';
    } catch (e) {
      return '';
    }
  }

  static hasUpdate(latest: string): boolean {
    if (latest.length === 0) {
      return false;
    }
    return latest !== UpdateChecker.normalize(CURRENT_VERSION);
  }

  static normalize(tag: string): string {
    return tag.trim().replace(/^v/i, '');
  }

  static currentVersion(): string {
    return CURRENT_VERSION;
  }
}
