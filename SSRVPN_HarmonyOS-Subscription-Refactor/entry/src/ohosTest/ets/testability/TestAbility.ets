import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import type Want from '@ohos.app.ability.Want';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const TAG = 'TestAbility';
const delegator = AbilityDelegatorRegistry.getAbilityDelegator();

export default class TestAbility extends UIAbility {
  onCreate(want: Want): void {
    hilog.info(0x0000, TAG, 'TestAbility onCreate');
    globalThis.abilityContext = this.context;
    globalThis.abilityWant = want;
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'TestAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, TAG, 'TestAbility onWindowStageCreate');
    windowStage.loadContent('testability/pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'TestAbility loadContent failed: %{public}s', JSON.stringify(err));
      } else {
        hilog.info(0x0000, TAG, 'TestAbility loadContent ok');
        globalThis.isLoadContentDone = true;
        delegator.sendState('');
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'TestAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, 'TestAbility onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, 'TestAbility onBackground');
  }
}
