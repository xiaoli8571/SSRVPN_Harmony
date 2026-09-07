/**
 * 应用入口 Ability
 * 移植自 upstream: SSRVPN_Android/lib/main.dart + app.dart + startup/*（启动编排的 ArkTS 等价）
 */
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SettingsService } from '../commons/services/SettingsService';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppLogger.info(TAG, 'onCreate');
    SettingsService.init(this.context).catch((e: BusinessError) => {
      AppLogger.error(TAG, `settings init failed: ${e.message}`);
    });
    // 自动连接请求透传（对应 AutoConnectRequestRegistry）
    if (want.parameters && want.parameters['auto_connect'] === '1') {
      AppStorage.setOrCreate('auto_connect_requested', true);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/HomePage', (err) => {
      if (err.code) {
        hilog.error(0x0, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      // 暗色状态栏对齐 upstream 暗色主题
      windowStage.getMainWindow((err2, win) => {
        if (!err2.code) {
          // 窗口背景设为深色: 否则安全区外(底部导航条区域)会露出默认白色,
          // 表现为页面最下方的"白条"。
          win.setWindowBackgroundColor('#0A1020');
          // 系统栏全透明: 页面背景的三段渐变已通过 expandSafeArea 延伸到
          // 状态栏/导航条之下, 顶部渐变色(#181B3B)直接透出, 无需再设固定色,
          // 避免"纯黑状态栏"与主题脱节。
          win.setWindowSystemBarProperties({
            statusBarColor: '#00000000',
            statusBarContentColor: '#F5F7FF',
            navigationBarColor: '#00000000',
            navigationBarContentColor: '#F5F7FF'
          }).catch(() => {});
        }
      });
    });
  }

  onDestroy(): void {
    AppLogger.info(TAG, 'onDestroy');
  }
}
