/**
 * VPN 扩展能力：TUN 建立、fd 注入内核、长时任务
 * 移植自 upstream: android/.../SsrvpnVpnService.kt
 *                VpnRouteInstaller.kt / VpnIpv6Config.kt / CoreLivenessMonitor.kt
 *
 * 真实 API（SDK @ohos.net.vpnExtension，API 11+ / 本机 SDK 26）：
 *   vpnExtension.createVpnConnection(context) → VpnConnection
 *   VpnConnection.create(VpnConfig) → Promise<number>（TUN fd）
 * 链路：UI 侧 ConnectionOrchestrator 写好配置文件并通过
 *   startVpnExtensionAbility(want.parameters.configPath) 拉起本能力 →
 *   本能力 onCreate 里 create() 拿到 fd → coreBridge.attachTun(fd) + startCore(configPath)。
 *
 * ⚠️ 生命周期回调名：VpnExtensionAbility 只有 onCreate(want) / onDestroy()，
 *    不存在 onStart/onStop（见 SDK @ohos.app.ability.VpnExtensionAbility.d.ts）。
 *    之前误用 onStart/onStop，系统回调命中基类空实现，TUN/内核从未启动，
 *    表现为 UI 侧 30s 超时报「9090 端口跨进程不可达」。
 *
 * IPv6 入站已常开（FlClash 常用功能之一，不提供关闭入口）：isIPv6Accepted=true，
 * IPv4+IPv6 双栈地址与默认路由；内核侧 dns.ipv6 + fake-ip fc00::/71 同步开启。
 * 长时任务：本 SDK 无 VPN 模式，使用 TASK_KEEPING（对应 Android 前台服务语义）。
 */
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { fileIo as fs } from '@kit.CoreFileKit';
import { coreBridge } from '../core/CoreBridge';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'VpnExtensionAbility';
const VPN_MTU = 1400;
/** TUN 地址/前缀与 bridge/bridge.go 的 Inet4Address 严格一致（对齐 NekoBox 实测格式） */
const TUN_ADDRESS = '172.19.0.1';
const TUN_PREFIX = 30;
/** IPv6 入站: ULA 地址 + /126, 与 mihomo tun.inet6-address 严格一致（对齐 NekoBox） */
const TUN_ADDRESS_V6 = 'fdfe:dcba:9876::1';
const TUN_PREFIX_V6 = 126;
const TUN_IFNAME = 'vpn-tun';
const DNS_SERVERS = ['223.5.5.5', '119.29.29.29'];
/** 启动错误回传文件名（写入 configPath 同目录，UI 侧读取真实失败原因） */
const START_ERROR_FILE = 'vpn_start_error.txt';
/** 启动成功标记文件名（内核 API 就绪后写入，UI 侧轮询） */
const START_OK_FILE = 'vpn_start_ok.txt';
/** 心跳文件名（内核运行期间每 3s 覆写时间戳，UI 侧据此判断内核存活） */
const HEARTBEAT_FILE = 'vpn_heartbeat.txt';
const HEARTBEAT_INTERVAL_MS = 3000;

export default class SsrvpnVpnExtension extends VpnExtensionAbility {
  /** 当前 VpnConnection（重入时先 destroy 旧的，避免 2200002 VPN already exist） */
  private connection: vpnExtension.VpnConnection | null = null;
  /** 心跳定时器（onDestroy 时清理） */
  private heartbeatTimer: number = -1;
  /** 把扩展进程内的启动失败原因写回 UI 可读的目录（跨进程无法直接共享内存） */
  private reportStartError(configPath: string, message: string): void {
    try {
      const dir = configPath.substring(0, configPath.lastIndexOf('/'));
      const file = fs.openSync(`${dir}/${START_ERROR_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, message);
      fs.closeSync(file);
    } catch (e) {
      AppLogger.warn(TAG, `write start error file failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /** 写入启动成功标记（内容为时间戳，便于排查） */
  private reportStartOk(configPath: string): void {
    try {
      const dir = configPath.substring(0, configPath.lastIndexOf('/'));
      const file = fs.openSync(`${dir}/${START_OK_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, `${Date.now()}`);
      fs.closeSync(file);
    } catch (e) {
      AppLogger.warn(TAG, `write start ok file failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private clearStartError(configPath: string): void {
    try {
      const dir = configPath.substring(0, configPath.lastIndexOf('/'));
      fs.unlinkSync(`${dir}/${START_ERROR_FILE}`);
      fs.unlinkSync(`${dir}/${START_OK_FILE}`);
      fs.unlinkSync(`${dir}/${HEARTBEAT_FILE}`);
    } catch (e) {
      // 文件不存在属正常
    }
  }

  /** 内核运行期间周期覆写心跳时间戳，UI 侧读取以判断内核存活 */
  private startHeartbeat(configPath: string): void {
    this.stopHeartbeat();
    const dir = configPath.substring(0, configPath.lastIndexOf('/'));
    this.heartbeatTimer = setInterval(() => {
      try {
        const file = fs.openSync(`${dir}/${HEARTBEAT_FILE}`,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, `${Date.now()}`);
        fs.closeSync(file);
      } catch (e) {
        AppLogger.warn(TAG, `heartbeat write failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    }, HEARTBEAT_INTERVAL_MS);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer >= 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  async onCreate(want: Want): Promise<void> {
    AppLogger.info(TAG, 'vpn onCreate');
    // 长时任务（对应 Android 前台服务），失败不阻塞连接流程
    try {
      const entryWant: Want = {
        bundleName: 'com.ssrvpn.harmonyos',
        abilityName: 'EntryAbility'
      };
      const agentRequest: wantAgent.WantAgentInfo = {
        wants: [entryWant],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(agentRequest);
      await backgroundTaskManager.startBackgroundRunning(this.context,
        backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
    } catch (e) {
      AppLogger.warn(TAG, `background task start failed: ${e instanceof Error ? e.message : String(e)}`);
    }

    const params = want.parameters;
    let configPath = (params !== undefined && params !== null) ? (params['configPath'] as string) : '';
    if (configPath === undefined || configPath.length === 0) {
      configPath = `${this.context.cacheDir}/mihomo_config.yaml`;
      AppLogger.warn(TAG, `want.parameters.configPath missing; fallback=${configPath}`);
    }
    this.clearStartError(configPath);

    // 重入防护：进程复用导致旧连接仍在时先销毁（避免 create 报 2200002 already exist）
    if (this.connection !== null) {
      try {
        await this.connection.destroy();
      } catch (e) {
        // 旧连接可能已失效，忽略
      }
      this.connection = null;
    }
    // 内核可能因进程复用而残留运行状态，先幂等停止再启动
    try {
      await coreBridge.stopCore();
    } catch (e) {
      // 未启动过时停止属正常
    }

    const config: vpnExtension.VpnConfig = {
      addresses: [{
        address: { address: TUN_ADDRESS, family: 1 },
        prefixLength: TUN_PREFIX
      }, {
        address: { address: TUN_ADDRESS_V6, family: 2 },
        prefixLength: TUN_PREFIX_V6
      }],
      // 默认路由捕获全部流量（对齐 NekoBox: interface 指定 TUN 名 + isDefaultRoute）;
      // IPv6 ::/0 为"IPv6 入站"常开项, 与内核 inet6-address/fake-ip fc00::/71 配套。
      routes: [{
        interface: TUN_IFNAME,
        destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: true
      }, {
        interface: TUN_IFNAME,
        destination: { address: { address: '::', family: 2 }, prefixLength: 0 },
        gateway: { address: '::', family: 2 },
        hasGateway: false,
        isDefaultRoute: true
      }],
      dnsAddresses: DNS_SERVERS,
      mtu: VPN_MTU,
      isIPv4Accepted: true,
      isIPv6Accepted: true
    };

    try {
      this.connection = vpnExtension.createVpnConnection(this.context);
      const tunFd = await this.connection.create(config);
      AppLogger.info(TAG, `TUN created, fd=${tunFd}`);

      // 防回环（对齐 NekoBox 的 protectProcessNet）：保护扩展进程（Go 内核所在进程）
      // 后续创建的 socket 绕过 VPN，代理出站与 DNS 引导走物理网络。
      // 不加的话内核出站连接会被 TUN 路由再次捕获，形成回环导致全部超时。
      try {
        await this.connection.protectProcessNet();
        AppLogger.info(TAG, 'protectProcessNet ok: core sockets bypass VPN');
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        this.reportStartError(configPath, `VPN 扩展启动异常: 防回环保护失败: ${msg}`);
        AppLogger.error(TAG, `protectProcessNet failed: ${msg}`);
        return;
      }

      const attached = await coreBridge.attachTun(tunFd, VPN_MTU);
      if (!attached) {
        this.reportStartError(configPath, '内核桥加载失败（attachTun）');
        AppLogger.error(TAG, 'attachTun failed (内核桥未加载?)');
        return;
      }

      // 内核（含 Clash API 控制面）在扩展进程内启动；成功后写 OK 标记给 UI 进程轮询
      const ok = await coreBridge.startCore(configPath);
      AppLogger.info(TAG, `core start result: ${ok}`);
      if (!ok) {
        const coreErr = await coreBridge.lastError();
        this.reportStartError(configPath, coreErr.length > 0 ? coreErr : '内核启动失败（未知原因）');
        AppLogger.error(TAG, `core error: ${coreErr}`);
        return;
      }
      this.reportStartOk(configPath);
      this.startHeartbeat(configPath);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.reportStartError(configPath, `VPN 扩展启动异常: ${msg}`);
      AppLogger.error(TAG, `vpn onCreate failed: ${msg}`);
    }
  }

  onDestroy(): void {
    AppLogger.info(TAG, 'vpn onDestroy');
    this.stopHeartbeat();
    try {
      coreBridge.stopCore();
    } catch (e) {
      // 忽略停止内核异常
    }
    if (this.connection !== null) {
      try {
        this.connection.destroy().catch(() => {});
      } catch (e) {
        // 忽略
      }
      this.connection = null;
    }
    try {
      backgroundTaskManager.stopBackgroundRunning(this.context).catch(() => {});
    } catch (e) {
      // 忽略停止后台任务异常
    }
  }
}
