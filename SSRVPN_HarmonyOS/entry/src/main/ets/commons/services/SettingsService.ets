/**
 * 设置持久化服务
 * 移植自 upstream: SSRVPN_Android/lib/services/settings_service.dart
 * - apiSecret：@ohos.security.asset（系统级加密存储，对应 Keystore AES-GCM / NativeApiSecretResolver）
 * - 连接快照：重启后恢复上次连接意图（对应 NativeConnectionSnapshotStore）
 */
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { AppSettings, AppSettingsJson } from '../models/AppSettings';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'SettingsService';
const PREF_NAME = 'ssrvpn_settings';
const KEY_SETTINGS = 'app_settings_json';
const ASSET_SERVICE = 'ssrvpn_service';
const ASSET_SECRET_KEY = 'api_secret';
const KEY_SNAPSHOT = 'connection_snapshot_json';

/** 连接快照（对应 NativeConnectionSnapshot：重启恢复连接意图） */
export class ConnectionSnapshot {
  desiredConnected: boolean = false;
  nodeName: string = '';
  savedAt: number = 0;
}

export class SettingsService {
  private static store: preferences.Preferences | null = null;

  static async init(context: Context): Promise<void> {
    SettingsService.store = await preferences.getPreferences(context, PREF_NAME);
  }

  static async load(): Promise<AppSettings> {
    if (SettingsService.store === null) {
      return new AppSettings();
    }
    const raw = await SettingsService.store.get(KEY_SETTINGS, '') as string;
    if (raw.length === 0) {
      return new AppSettings();
    }
    try {
      const j = JSON.parse(raw) as AppSettingsJson;
      return AppSettings.fromJson(j);
    } catch (e) {
      return new AppSettings();
    }
  }

  static async save(settings: AppSettings): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    await SettingsService.store.put(KEY_SETTINGS, JSON.stringify(settings.toJson()));
    await SettingsService.store.flush();
  }

  /** apiSecret 只允许存入系统加密 AssetStore，禁止降级到明文 Preferences。 */
  static async setApiSecret(secret: string): Promise<void> {
    const attr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attr.set(asset.Tag.SECRET, stringToUint8(secret));
    attr.set(asset.Tag.ALIAS, stringToUint8(ASSET_SECRET_KEY));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.remove(attr);
    } catch (e) {
      // 首次写入前不存在属正常
    }
    await asset.add(attr);

    // 清除旧版本可能遗留的明文回退值。
    if (SettingsService.store !== null) {
      try {
        await SettingsService.store.delete('api_secret_fallback');
        await SettingsService.store.flush();
      } catch (cleanupError) {
        AppLogger.warn(TAG, `failed to remove legacy api secret fallback: ${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`);
      }
    }
    AppLogger.info(TAG, 'apiSecret stored in asset store');
  }

  static async getApiSecret(): Promise<string> {
    try {
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.ALIAS, stringToUint8(ASSET_SECRET_KEY));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results: asset.AssetMap[] = await asset.query(query);
      if (results.length === 0) {
        return '';
      }
      const secretVal = results[0].get(asset.Tag.SECRET);
      if (secretVal !== undefined && secretVal instanceof Uint8Array) {
        return uint8ToString(secretVal as Uint8Array);
      }
      return '';
    } catch (e) {
      AppLogger.warn(TAG, `asset store query failed: ${e instanceof Error ? e.message : String(e)}`);
      return '';
    }
  }

  /** 连接快照读写（重启恢复） */
  static async saveSnapshot(snap: ConnectionSnapshot): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    await SettingsService.store.put(KEY_SNAPSHOT, JSON.stringify(snap));
    await SettingsService.store.flush();
  }

  static async loadSnapshot(): Promise<ConnectionSnapshot> {
    const snap = new ConnectionSnapshot();
    if (SettingsService.store === null) {
      return snap;
    }
    const raw = await SettingsService.store.get(KEY_SNAPSHOT, '') as string;
    if (raw.length === 0) {
      return snap;
    }
    try {
      const j = JSON.parse(raw) as ConnectionSnapshot;
      snap.desiredConnected = j.desiredConnected;
      snap.nodeName = j.nodeName;
      snap.savedAt = j.savedAt;
    } catch (e) {
      // 快照损坏则视为空
    }
    return snap;
  }
}

function stringToUint8(s: string): Uint8Array {
  return util.TextEncoder.create('utf-8').encodeInto(s);
}

function uint8ToString(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}
