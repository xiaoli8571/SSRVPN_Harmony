import TestRunner from '@ohos.application.testRunner';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';

const abilityDelegator = AbilityDelegatorRegistry.getAbilityDelegator();

export default class OpenHarmonyTestRunner extends TestRunner {
  constructor() {
    super();
  }

  onPreparing(): void {
  }

  onRunning(): void {
  }

  onRun(): void {
    abilityDelegator.run();
  }
}
