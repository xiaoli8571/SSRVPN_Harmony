/**
 * 无界面快捷执行宿主：桌面图标长按「启动代理」的目标 Ability。
 *
 * 与 EntryAbility 的区别：不 loadContent 任何页面，onCreate 里直接跑
 * VpnQuickStart（后台连接/断开），完成后立即 terminateSelf —— 用户视角
 * 只有深色启动窗一闪（系统强制的窗口生命周期），不会进入应用界面。
 * removeMissionAfterTerminate=true 保证结束后不留任务栏卡片。
 */
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { VpnQuickStart } from '../commons/services/VpnQuickStart';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'QuickToggleAbility';

export default class QuickToggleAbility extends UIAbility {
  private running: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const mode = (want.parameters !== undefined && want.parameters['vpn_shortcut'] === 'start')
      ? 'start' : 'toggle';
    this.run(mode);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (this.running) {
      return; // 上一次还没跑完, 忽略重复触发
    }
    const mode = (want.parameters !== undefined && want.parameters['vpn_shortcut'] === 'start')
      ? 'start' : 'toggle';
    this.run(mode);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 故意不 loadContent: 本能力没有任何页面, 窗口只是系统生命周期的载体。
  }

  private run(mode: string): void {
    this.running = true;
    AppLogger.info(TAG, `quick action started: mode=${mode}`);
    VpnQuickStart.run(mode, this.context).then((result: string) => {
      AppLogger.info(TAG, `quick action done: ${result}, terminating`);
      this.running = false;
      this.context.terminateSelf().catch(() => {
      });
    });
  }
}
