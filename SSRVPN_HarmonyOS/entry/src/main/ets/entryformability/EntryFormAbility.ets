/**
 * SSRVPN 桌面服务卡片 FormExtensionAbility。
 * 卡片点击在后台执行，生命周期回调只读取本地节点、进程状态、应用内存和公网 IP 缓存做轻量校准。
 */
import FormExtensionAbility from '@ohos.app.form.FormExtensionAbility';
import formBindingData from '@ohos.app.form.formBindingData';
import type Want from '@ohos.app.ability.Want';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VpnQuickStart } from '../commons/services/VpnQuickStart';
import { FormStateSync, FormStateSnapshot, TOGGLE_FORM_NAME } from '../commons/services/FormStateSync';
import { FormInfoMetrics } from '../commons/services/FormInfoMetrics';

const TAG = 'EntryFormAbility';
const FORM_ID_KEY = 'ohos.extra.param.key.form_identity';
const FORM_NAME_KEY = 'ohos.extra.param.key.form_name';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = this.formIdFromWant(want);
    const formName = this.formNameFromWant(want);
    hilog.info(0x5256, TAG, `onAddForm formId=${formId} formName=${formName}`);
    if (formId.length > 0) {
      FormStateSync.addForm(this.context, formId, formName).catch((): void => {
        hilog.warn(0x5256, TAG, 'addForm failed');
      });
    }

    // FormKit 要求同步返回。先用本地进程/心跳的即时结果避免已连接时闪成未连接，
    // 随后异步读取持久化节点，并按卡片类型补充内存和缓存公网 IP。
    const initial = FormStateSync.immediate(this.context);
    if (formId.length > 0) {
      this.calibrateOne(formId);
    }
    return formBindingData.createFormBindingData(initial);
  }

  onCastToNormalForm(formId: string): void {
    hilog.info(0x5256, TAG, `onCastToNormalForm formId=${formId}`);
    this.calibrateOne(formId);
  }

  onUpdateForm(formId: string): void {
    hilog.info(0x5256, TAG, `onUpdateForm formId=${formId}`);
    this.calibrateOne(formId);
  }

  onChangeFormVisibility(newStatus: Record<string, number>): void {
    for (const formId of Object.keys(newStatus)) {
      if (newStatus[formId] > 0) {
        this.calibrateOne(formId);
      }
    }
  }

  /** 卡片 postCardAction('message') 入口，后台执行且不打开页面。 */
  onFormEvent(formId: string, event: string): void {
    let command = '';
    try {
      const payload = JSON.parse(event) as Record<string, string>;
      command = payload['command'] ?? '';
    } catch (error) {
      hilog.warn(0x5256, TAG, 'onFormEvent bad payload');
      return;
    }

    if (command === 'refresh_public_ip') {
      if (VpnQuickStart.isBusy()) {
        return;
      }
      FormInfoMetrics.refreshPublicIp(this.context, true).then((): Promise<FormStateSnapshot> => {
        return FormStateSync.calibrate(this.context);
      }).then((snapshot: FormStateSnapshot): Promise<void> => {
        return FormStateSync.updateRegisteredOne(this.context, formId, snapshot);
      }).catch((): void => {
        hilog.warn(0x5256, TAG, 'public IP refresh failed');
      });
      return;
    }

    if (command !== 'toggle') {
      return;
    }
    // toggle 必须始终交给 VpnQuickStart。连接操作进行中再次收到 toggle 时，
    // VpnQuickStart 会记录 pending disconnect 并使旧 connect 代际失效；
    // 不能在 FormExtensionAbility 这一层用 busy 判断吞掉用户的断开意图。
    VpnQuickStart.run('toggle', this.context).catch((): void => {
      hilog.warn(0x5256, TAG, 'toggle failed');
    });
  }

  onRemoveForm(formId: string): void {
    FormStateSync.removeFormId(this.context, formId).catch((): void => {
      hilog.warn(0x5256, TAG, 'removeFormId failed');
    });
  }

  onDestroy(): void {
    FormStateSync.stopInfoRefresh();
  }

  onConfigurationUpdate(config: Record<string, Object>): void {
    FormStateSync.calibrate(this.context).then((snapshot: FormStateSnapshot): Promise<void> => {
      return FormStateSync.publish(this.context, snapshot);
    }).catch((): void => {
      hilog.warn(0x5256, TAG, 'configuration refresh failed');
    });
  }

  private calibrateOne(formId: string): void {
    FormStateSync.calibrate(this.context).then((snapshot: FormStateSnapshot): Promise<void> => {
      return FormStateSync.updateRegisteredOne(this.context, formId, snapshot);
    }).catch((): void => {
      hilog.warn(0x5256, TAG, `calibrate failed formId=${formId}`);
    });
  }

  private formIdFromWant(want: Want): string {
    const parameters = want.parameters;
    if (parameters === undefined || parameters === null) {
      return '';
    }
    return `${parameters[FORM_ID_KEY] ?? ''}`;
  }

  private formNameFromWant(want: Want): string {
    const parameters = want.parameters;
    if (parameters === undefined || parameters === null) {
      return TOGGLE_FORM_NAME;
    }
    const formName = `${parameters[FORM_NAME_KEY] ?? ''}`;
    return formName.length > 0 ? formName : TOGGLE_FORM_NAME;
  }
}
