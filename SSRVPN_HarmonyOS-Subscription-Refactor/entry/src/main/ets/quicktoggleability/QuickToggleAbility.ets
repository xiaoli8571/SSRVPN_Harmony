/**
 * 无界面快捷执行宿主：桌面图标长按「启动代理」的目标 Ability。
 *
 * 与 EntryAbility 的区别：不 loadContent 任何页面，onCreate 里直接跑
 * VpnQuickStart（后台连接/断开），完成后立即 terminateSelf —— 用户视角
 * 不应看到任何界面。removeMissionAfterTerminate=true 保证结束后不留任务栏卡片。
 *
 * 真机取证结论（2026-09-10，HarmonyOS 6.1 / 设备 192.168.10.6）：
 *   长按桌面图标触发本能力的「闪一下」并不是崩溃 —— 设备侧同时满足
 *   ① `aa start -b com.ssrvpn.client -a QuickToggleAbility -m entry --ps vpn_shortcut start`
 *      返回 `start ability successfully.`；
 *   ② 应用日志完整走出 `quick action started: mode=start` → `connected to node …`
 *      → `quick start => on` → `quick action done: on`；
 *   ③ hilog 全量缓冲中无 jscrash / SIGSEGV / Uncaught / TypeError / AppFreeze；
 *   ④ 主进程存活、VPN 扩展进程 `com.ssrvpn.client:vpn` 正常拉起并持续写心跳；
 *   ⑤ 系统侧日志显示桌面（sceneboard）为一个无页面的 UIAbility 建了整屏 window scene
 *      （`startSceneFromOther` → `sceneAlpha 0→1` → `requestSceneContainerDestruction…delete:true`
 *      → `AppLifeCycleManager: Ability state trminated`）。
 *   即：闪一下是「系统启动窗（start window）被显示 → 能力自毁」的必然结果，
 *   属于无界面能力的设计副产物，而不是异常退出。
 *
 * 因此本文件做三件事：
 *   1) 让这面窗口彻底隐形（启动窗透明 + 主窗口背景透明），把「一闪」压到不可见；
 *   2) 收紧生命周期与 terminateSelf 时序：只在 windowStage 就绪后自毁，避免
 *      `[JUA2516]null windowStage` 这类窗口状态错位，并加兜底寿命守护；
 *   3) 所有分支（含失败）写可观测通道（ShortcutOutcomeLog），失败原因可事后取证。
 * 重复点击 / 已连接状态下点击均幂等：单航班 + 末次意图合并，绝不吞点击，也不重复拉起。
 */
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { VpnQuickStart } from '../commons/services/VpnQuickStart';
import { ShortcutOutcomeLog, ShortcutOutcomeRecord } from '../commons/services/ShortcutOutcomeLog';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'QuickToggleAbility';
/** 明确「只连接」的快捷方式参数值（与 shortcuts_config.json 保持一致） */
const MODE_START = 'start';
/** 无参数/其它值一律按切换处理（服务卡片等入口共用） */
const MODE_TOGGLE = 'toggle';
/** 完全透明色：用于抹掉无界面能力的启动窗与主窗口底色 */
const COLOR_TRANSPARENT = '#00000000';
/**
 * 兜底寿命守护：无页面能力一旦悬留就是一块黑屏，任何异常路径都不允许它常驻。
 * 正常路径（含内核拉起最长 20s）应在 20s 内结束，此处给足余量。
 */
const MAX_LIFETIME_MS = 30000;
/** 自毁前等待 windowStage 就绪的上限（极快的「已连接」短路会早于窗口创建） */
const WINDOW_STAGE_GRACE_MS = 1500;
/** 轮询 windowStage 就绪的步长 */
const WINDOW_STAGE_POLL_MS = 100;

export default class QuickToggleAbility extends UIAbility {
  private running: boolean = false;
  private pendingMode: string = '';
  private windowStageReady: boolean = false;
  private destroyScheduled: boolean = false;
  private destroyed: boolean = false;
  private lifetimeTimer: number = -1;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.armLifetimeGuard();
    AppLogger.info(TAG, 'headless host created (no page loaded by design)');
    this.enqueue(this.resolveMode(want));
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 复用任务栈时的第二次点击（长按图标 → 启动代理）：必须继续生效，不能静默丢弃。
    if (this.destroyed) {
      return;
    }
    AppLogger.info(TAG, 'headless host re-used (onNewWant)');
    this.enqueue(this.resolveMode(want));
  }

  onForeground(): void {
    this.drain();
  }

  onBackground(): void {
    // 前台的窗口生命周期可能被系统提前收起；在途任务照常继续，这里只做推进。
    this.drain();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStageReady = true;
    this.blindWindow(windowStage);
    this.drain();
  }

  onWindowStageDestroy(): void {
    this.windowStageReady = false;
  }

  onDestroy(): void {
    this.destroyed = true;
    this.running = false;
    this.pendingMode = '';
    this.windowStageReady = false;
    this.clearLifetimeGuard();
    AppLogger.info(TAG, 'headless host destroyed');
  }

  /**
   * 把无内容窗口彻底变透明。
   * 这里全部是 UI-only 调用：headless 路径下必须独立 try/catch，
   * 任何失败只降级为「可能可见一闪」，绝不能把整个快捷动作带崩。
   */
  private blindWindow(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.setWindowBackgroundColor(COLOR_TRANSPARENT);
    } catch (error) {
      AppLogger.warn(TAG,
        `blind window failed (UI-only API): ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private resolveMode(want: Want): string {
    const params = want.parameters;
    if (params !== undefined && params['vpn_shortcut'] === MODE_START) {
      return MODE_START;
    }
    return MODE_TOGGLE;
  }

  /** 合并为最后一次有效意图，但绝不因能力已启动或前一次尚未完成而静默丢弃。 */
  private enqueue(mode: string): void {
    if (this.destroyed) {
      return;
    }
    this.pendingMode = mode;
    this.drain();
  }

  private drain(): void {
    if (this.destroyed || this.running || this.pendingMode.length === 0) {
      return;
    }
    const mode = this.pendingMode;
    this.pendingMode = '';
    this.running = true;
    const startedAt = Date.now();
    AppLogger.info(TAG, `quick action started: mode=${mode}`);
    VpnQuickStart.run(mode, this.context).then((result: string): void => {
      AppLogger.info(TAG, `quick action done: ${result}`);
      this.recordOutcome(mode, result, '', startedAt);
    }).catch((error: Error): void => {
      AppLogger.error(TAG, `quick action failed: ${error.message}`);
      this.recordOutcome(mode, 'failed', error.message, startedAt);
    }).finally((): void => {
      this.running = false;
      if (this.destroyed) {
        return;
      }
      if (this.pendingMode.length > 0) {
        this.drain();
        return;
      }
      this.scheduleSelfDestroy();
    });
  }

  private recordOutcome(mode: string, result: string, detail: string, startedAt: number): void {
    const record = new ShortcutOutcomeRecord();
    record.at = Date.now();
    record.mode = mode;
    record.result = result;
    record.detail = detail.length > 0 ? detail : VpnQuickStart.lastDetail();
    record.elapsedMs = Date.now() - startedAt;
    ShortcutOutcomeLog.record(this.context, record);
  }

  /**
   * 自毁时序修正：terminateSelf 必须发生在 windowStage 创建之后。
   * 若在 onCreate 里同步短路完（如「已连接」直接返回 already）就立刻 terminateSelf，
   * 框架会以 null windowStage 走窗口销毁路径（真机 hilog 里的 [JUA2516]null windowStage），
   * 窗口状态错位且有把启动窗留在屏幕上的风险。这里最多等 WINDOW_STAGE_GRACE_MS。
   */
  private scheduleSelfDestroy(): void {
    if (this.destroyScheduled || this.destroyed) {
      return;
    }
    this.destroyScheduled = true;
    if (this.windowStageReady) {
      this.terminate('window-stage-ready');
      return;
    }
    let waited = 0;
    const step = (): void => {
      if (this.destroyed) {
        return;
      }
      if (this.windowStageReady) {
        this.terminate('window-stage-late');
        return;
      }
      waited = waited + WINDOW_STAGE_POLL_MS;
      if (waited >= WINDOW_STAGE_GRACE_MS) {
        this.terminate('window-stage-timeout');
        return;
      }
      setTimeout(step, WINDOW_STAGE_POLL_MS);
    };
    setTimeout(step, WINDOW_STAGE_POLL_MS);
  }

  private terminate(reason: string): void {
    if (this.destroyed) {
      return;
    }
    this.destroyed = true;
    this.clearLifetimeGuard();
    AppLogger.info(TAG, `terminateSelf (${reason})`);
    this.context.terminateSelf().catch((error: Error): void => {
      // 自毁失败不重试（重试可能循环）：只记录，交给兜底寿命守护与系统回收。
      AppLogger.warn(TAG, `terminateSelf failed: ${error.message}`);
    });
  }

  private armLifetimeGuard(): void {
    this.clearLifetimeGuard();
    this.lifetimeTimer = setTimeout((): void => {
      this.lifetimeTimer = -1;
      AppLogger.warn(TAG, 'lifetime guard fired: forcing terminate to avoid a stuck blank window');
      this.terminate('lifetime-guard');
    }, MAX_LIFETIME_MS);
  }

  private clearLifetimeGuard(): void {
    if (this.lifetimeTimer >= 0) {
      clearTimeout(this.lifetimeTimer);
      this.lifetimeTimer = -1;
    }
  }
}
