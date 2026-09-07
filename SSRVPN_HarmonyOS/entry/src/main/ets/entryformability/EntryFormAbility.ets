/**
 * 服务卡片（对应 upstream VpnTileService：系统级一键连接/断开）
 * FormKit 服务卡片：点击卡片按钮 postCardAction 跳转 EntryAbility，由主页执行连接/断开。
 */
import FormExtensionAbility from '@ohos.app.form.FormExtensionAbility';
import formBindingData from '@ohos.app.form.formBindingData';
import type Want from '@ohos.app.ability.Want';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'EntryFormAbility';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    hilog.info(0x5256, TAG, 'onAddForm');
    const data: Record<string, string> = { 'state': '未连接' };
    return formBindingData.createFormBindingData(data);
  }

  onCastToNormalForm(formId: string): void {
    hilog.info(0x5256, TAG, 'onCastToNormalForm');
  }

  onUpdateForm(formId: string): void {
    // 状态由主页在连接状态变化时通过 formProvider 更新
  }

  onChangeFormVisibility(newStatus: Record<string, number>): void {
  }

  onFormEvent(formId: string, event: string): void {
    hilog.info(0x5256, TAG, 'onFormEvent');
  }

  onRemoveForm(formId: string): void {
  }

  onConfigurationUpdate(config: Record<string, Object>): void {
  }
}
