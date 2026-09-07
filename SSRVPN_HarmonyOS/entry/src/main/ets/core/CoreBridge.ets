/**
 * 内核桥（NAPI 封装的 ArkTS 侧接口）
 * 移植自 upstream: SSRVPN_Android/lib/services/clash_service_native_bridge.dart
 *                android/.../kotlin/bridge/Bridge.kt
 *
 * 底层由 entry/src/main/cpp (NAPI) 加载 libgojni.so（Mihomo c-shared 内核）实现。
 * ABI（cshared_main.go 导出）：
 *   SsrvpnInit(homeDir, configFile) / SsrvpnStart(configPath, tunFd) /
 *   SsrvpnStop() / SsrvpnIsRunning() / SsrvpnVersion() / SsrvpnLastError()
 */
import native from 'libssrvpn_core_napi.so';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'CoreBridge';
const CORE_LIB = 'libgojni.so';

export class CoreBridgeImpl {
  private loaded: boolean = false;
  private tunFd: number = -1;

  private ensureLoaded(): boolean {
    if (this.loaded) {
      return true;
    }
    this.loaded = true;
    AppLogger.info(TAG, `${CORE_LIB} bridge module registered`);
    AppLogger.info(TAG, `native module type=${typeof native}, attachTunFd=${typeof native.attachTunFd}, startCore=${typeof native.startCore}`);
    return true;
  }

  /** VpnExtensionAbility 在 TUN 建立后调用：注入 fd */
  async attachTun(fd: number, mtu: number): Promise<boolean> {
    if (!this.ensureLoaded()) {
      return false;
    }
    this.tunFd = fd;
    return native.attachTunFd(fd, mtu);
  }

  /** 启动内核（configPath 为已写入的 Mihomo YAML 文件路径） */
  async startCore(configPath: string): Promise<boolean> {
    if (!this.ensureLoaded()) {
      return false;
    }
    return native.startCore(configPath, this.tunFd);
  }

  async stopCore(): Promise<void> {
    native.stopCore();
  }

  async isCoreAlive(): Promise<boolean> {
    return native.isCoreAlive();
  }

  async coreVersion(): Promise<string> {
    return native.coreVersion();
  }

  async lastError(): Promise<string> {
    return native.lastError();
  }
}

export const coreBridge: CoreBridgeImpl = new CoreBridgeImpl();
