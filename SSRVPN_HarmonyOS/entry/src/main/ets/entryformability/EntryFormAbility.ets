/**
 * 服务卡片（对应 upstream VpnTileService：系统级一键连接/断开）
 * FormKit 服务卡片：卡片按钮 postCardAction('message') → onFormEvent 在
 * FormExtension 后台回调中直接执行连接/断开（不拉起任何页面），
 * 完成后 formProvider.updateForm 回写卡片状态文案。
 */
import FormExtensionAbility from '@ohos.app.form.FormExtensionAbility';
import formBindingData from '@ohos.app.form.formBindingData';
import formProvider from '@ohos.app.form.formProvider';
import type Want from '@ohos.app.ability.Want';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VpnQuickStart } from '../commons/services/VpnQuickStart';
import { FormStateSync } from '../commons/services/FormStateSync';

const TAG = 'EntryFormAbility';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    hilog.info(0x5256, TAG, 'onAddForm');
    // 登记 formId 清单, 供状态广播 updateForm 定位目标
    const params = want.parameters;
    if (params !== undefined && params !== null) {
      const formId = `${params['ohos.extra.param.key.form_identity'] ?? ''}`;
      if (formId.length > 0) {
        FormStateSync.addFormId(this.context, formId);
      }
    }
    const data: Record<string, string> = { 'state': '未连接' };
    return formBindingData.createFormBindingData(data);
  }

  onCastToNormalForm(formId: string): void {
    hilog.info(0x5256, TAG, 'onCastToNormalForm');
  }

  onUpdateForm(formId: string): void {
    // 状态由卡片点击回调与主页在连接状态变化时通过 formProvider 更新
  }

  onChangeFormVisibility(newStatus: Record<string, number>): void {
  }

  /** 卡片 postCardAction('message') 入口: 后台执行, 不开页面 */
  onFormEvent(formId: string, event: string): void {
    let command = '';
    try {
      const obj = JSON.parse(event) as Record<string, string>;
      command = obj['command'] ?? '';
    } catch (e) {
      hilog.warn(0x5256, TAG, 'onFormEvent bad payload');
      return;
    }
    if (command !== 'toggle') {
      return;
    }
    hilog.info(0x5256, TAG, 'onFormEvent toggle (background)');
    VpnQuickStart.run('toggle', this.context).then((result: string) => {
      const state = result === 'on' || result === 'already' ? '已连接'
        : (result === 'off' ? '未连接' : (result === 'no_node' ? '无可用节点' : '连接失败'));
      const data: Record<string, string> = { 'state': state };
      formProvider.updateForm(formId, formBindingData.createFormBindingData(data)).catch(() => {
        hilog.warn(0x5256, TAG, 'updateForm failed');
      });
    });
  }

  onRemoveForm(formId: string): void {
    FormStateSync.removeFormId(this.context, formId);
  }

  onConfigurationUpdate(config: Record<string, Object>): void {
  }
}
