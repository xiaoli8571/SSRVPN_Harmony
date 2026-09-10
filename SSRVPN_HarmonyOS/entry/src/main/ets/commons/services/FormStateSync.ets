/**
 * 桌面服务卡片状态同步。
 *
 * 统一负责：真实状态轻量校准、结构化 BindingData、全部卡片广播、
 * formId 串行增删和失效 ID 批量清理。这里仅读取本地状态与持久化数据，
 * 不刷新订阅、不访问公网，也不做秒级轮询。
 */
import { formBindingData, formProvider } from '@kit.FormKit';
import { preferences } from '@kit.ArkData';
import { ConnectionOrchestrator, ConnState } from './ConnectionOrchestrator';
import { SettingsService } from './SettingsService';
import { SubscriptionService } from './SubscriptionService';
import { ProxyNode } from '../models/ProxyNode';
import { AppLogger } from '../utils/AppLogger';
import { FormInfoMetrics } from './FormInfoMetrics';

const TAG = 'FormStateSync';
const FORM_PREF = 'ssrvpn_forms';
const FORM_IDS_KEY = 'form_ids';
const FORM_RECORDS_KEY = 'form_records';
export const TOGGLE_FORM_NAME = 'SsrvpnToggleCard';
export const INFO_FORM_NAME = 'SsrvpnInfoCard';
const INFO_REFRESH_INTERVAL_MS = 5000;

class FormRecord {
  formId: string = '';
  formName: string = TOGGLE_FORM_NAME;
}

export enum FormStateCode {
  DISCONNECTED = 'disconnected',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  DISCONNECTING = 'disconnecting',
  RECOVERING = 'recovering',
  NO_NODE = 'no_node',
  FAILED = 'failed'
}

/** 使用 class 避免 ArkTS 无类型对象字面量，同时直接作为 Form BindingData。 */
export class FormStateSnapshot {
  stateCode: string = FormStateCode.DISCONNECTED;
  stateLabel: string = '未连接';
  nodeName: string = '未选择节点';
  actionLabel: string = '连接';
  busy: boolean = false;
  memoryText: string = '--';
  publicIp: string = '--';
  uploadSpeedText: string = '0 B/s';
  downloadSpeedText: string = '0 B/s';
  accessibilityLabel: string = 'SSRVPN，未连接，未选择节点，连接';
}

export class FormStateSync {
  /** preferences 清单变更串行化，防止 add/remove/失效清理并发覆盖。 */
  private static idMutationTail: Promise<void> = Promise.resolve();
  /** 状态发布串行化，避免较早的异步广播晚于新状态落地。 */
  private static publishTail: Promise<void> = Promise.resolve();
  /** 仅有信息卡片登记时运行的低频指标刷新器。 */
  private static infoRefreshTimer: number = -1;
  private static infoRefreshContext: Context | null = null;

  static disconnected(nodeName: string = ''): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.DISCONNECTED, nodeName);
  }

  static connecting(nodeName: string): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.CONNECTING, nodeName);
  }

  static connected(nodeName: string): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.CONNECTED, nodeName);
  }

  static disconnecting(nodeName: string): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.DISCONNECTING, nodeName);
  }

  static recovering(nodeName: string): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.RECOVERING, nodeName);
  }

  static noNode(): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.NO_NODE, '未选择节点');
  }

  static failed(nodeName: string = ''): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.FAILED, nodeName);
  }

  /**
   * 为 onAddForm 的同步返回提供即时状态。只读取进程状态和本地心跳，
   * 不执行异步初始化；完整节点信息由随后的 calibrate() 回填。
   */
  static immediate(context: Context): FormStateSnapshot {
    const orchestrator = ConnectionOrchestrator.instance();
    orchestrator.init(context);
    if (orchestrator.state === ConnState.CONNECTING) {
      return FormStateSync.connecting('');
    }
    if (orchestrator.state === ConnState.DISCONNECTING) {
      return FormStateSync.disconnecting('');
    }
    if (orchestrator.state === ConnState.RECOVERING) {
      return FormStateSync.recovering('');
    }
    if (orchestrator.isTunnelAlive()) {
      return FormStateSync.connected('');
    }
    if (orchestrator.lastError.length > 0) {
      return FormStateSync.failed('');
    }
    return FormStateSync.disconnected('');
  }

  /**
   * 读取本地持久化节点和隧道心跳，生成真实快照。
   * 可安全用于 onAddForm/onUpdateForm/onChangeFormVisibility。
   */
  static async calibrate(context: Context): Promise<FormStateSnapshot> {
    try {
      await SettingsService.init(context);
      const subscriptions = new SubscriptionService();
      await subscriptions.init(context);
      const settings = await SettingsService.load();
      const selected: ProxyNode | null = subscriptions.findNode(settings.preferredNodeId)
        ?? (subscriptions.nodes.length > 0 ? subscriptions.nodes[0] : null);
      const nodeName = selected === null ? '' : selected.name;
      const orchestrator = ConnectionOrchestrator.instance();
      orchestrator.init(context);

      if (orchestrator.state === ConnState.CONNECTING) {
        return FormStateSync.connecting(nodeName);
      }
      if (orchestrator.state === ConnState.DISCONNECTING) {
        return FormStateSync.disconnecting(nodeName);
      }
      if (orchestrator.state === ConnState.RECOVERING) {
        return FormStateSync.recovering(nodeName);
      }
      if (orchestrator.isTunnelAlive()) {
        return FormStateSync.connected(nodeName);
      }
      if (selected === null) {
        return FormStateSync.noNode();
      }
      if (orchestrator.lastError.length > 0) {
        return FormStateSync.failed(nodeName);
      }
      return FormStateSync.disconnected(nodeName);
    } catch (error) {
      AppLogger.warn(TAG, `calibrate failed: ${error instanceof Error ? error.message : String(error)}`);
      return FormStateSync.disconnected();
    }
  }

  /** EntryFormAbility 新增卡片时按 formId/formName 登记。 */
  static addForm(context: Context, formId: string, formName: string): Promise<void> {
    return FormStateSync.enqueueIdMutation(async (): Promise<void> => {
      const records = await FormStateSync.readFormRecords(context);
      let found = false;
      for (const record of records) {
        if (record.formId === formId) {
          record.formName = FormStateSync.normalizeFormName(formName);
          found = true;
          break;
        }
      }
      if (!found) {
        const record = new FormRecord();
        record.formId = formId;
        record.formName = FormStateSync.normalizeFormName(formName);
        records.push(record);
      }
      await FormStateSync.writeFormRecords(context, records);
      FormStateSync.reconcileInfoRefresh(context, records);
    });
  }

  /** 兼容已有调用，旧登记默认视为快捷开关卡片。 */
  static addFormId(context: Context, formId: string): Promise<void> {
    return FormStateSync.addForm(context, formId, TOGGLE_FORM_NAME);
  }

  /** EntryFormAbility 移除卡片时销账。 */
  static removeFormId(context: Context, formId: string): Promise<void> {
    return FormStateSync.removeFormIds(context, [formId]);
  }

  /** 单卡片更新，生命周期校准使用。 */
  static async updateOne(formId: string, snapshot: FormStateSnapshot): Promise<void> {
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(snapshot));
  }

  /** 按卡片类型补充信息字段。普通生命周期仅读内存和公网 IP 缓存。 */
  static async updateRegisteredOne(context: Context, formId: string,
    snapshot: FormStateSnapshot): Promise<void> {
    const formName = await FormStateSync.formNameForId(context, formId);
    const payload = formName === INFO_FORM_NAME
      ? await FormStateSync.withInfoMetrics(context, snapshot) : snapshot;
    await FormStateSync.updateOne(formId, payload);
  }

  /** 广播结构化状态到全部登记卡片。 */
  static publish(context: Context, snapshot: FormStateSnapshot): Promise<void> {
    const task = FormStateSync.publishTail.then(async (): Promise<void> => {
      const records = await FormStateSync.readFormRecords(context);
      const invalidIds: string[] = [];
      let infoSnapshot: FormStateSnapshot | null = null;
      for (const record of records) {
        try {
          let payload = snapshot;
          if (record.formName === INFO_FORM_NAME) {
            if (infoSnapshot === null) {
              infoSnapshot = await FormStateSync.withInfoMetrics(context, snapshot);
            }
            payload = infoSnapshot;
          }
          await FormStateSync.updateOne(record.formId, payload);
        } catch (error) {
          invalidIds.push(record.formId);
          AppLogger.warn(TAG, `updateForm failed: formId=${record.formId}`);
        }
      }
      if (invalidIds.length > 0) {
        await FormStateSync.removeFormIds(context, invalidIds);
      }
    });
    FormStateSync.publishTail = task.catch((): void => {
    });
    return task;
  }

  /** 兼容无需 await 的状态发布调用点；错误不影响 VPN 主流程。 */
  static push(context: Context, snapshot: FormStateSnapshot): void {
    FormStateSync.publish(context, snapshot).catch((error: Error): void => {
      AppLogger.warn(TAG, `publish failed: ${error.message}`);
    });
  }

  private static createSnapshot(stateCode: FormStateCode, nodeName: string): FormStateSnapshot {
    const snapshot = new FormStateSnapshot();
    snapshot.stateCode = stateCode;
    snapshot.nodeName = nodeName.length > 0 ? nodeName : '未选择节点';
    if (stateCode === FormStateCode.CONNECTING) {
      snapshot.stateLabel = '连接中';
      snapshot.actionLabel = '连接中';
      snapshot.busy = true;
    } else if (stateCode === FormStateCode.CONNECTED) {
      snapshot.stateLabel = '已连接';
      snapshot.actionLabel = '断开';
    } else if (stateCode === FormStateCode.DISCONNECTING) {
      snapshot.stateLabel = '断开中';
      snapshot.actionLabel = '断开中';
      snapshot.busy = true;
    } else if (stateCode === FormStateCode.RECOVERING) {
      snapshot.stateLabel = '恢复中';
      snapshot.actionLabel = '请稍候';
      snapshot.busy = true;
    } else if (stateCode === FormStateCode.NO_NODE) {
      snapshot.stateLabel = '无可用节点';
      snapshot.actionLabel = '打开应用';
    } else if (stateCode === FormStateCode.FAILED) {
      snapshot.stateLabel = '连接失败';
      snapshot.actionLabel = '重试';
    } else {
      snapshot.stateLabel = '未连接';
      snapshot.actionLabel = '连接';
    }
    snapshot.accessibilityLabel = `SSRVPN，${snapshot.stateLabel}，当前节点${snapshot.nodeName}，${snapshot.actionLabel}`;
    return snapshot;
  }

  private static enqueueIdMutation(operation: () => Promise<void>): Promise<void> {
    const task = FormStateSync.idMutationTail.then(operation);
    FormStateSync.idMutationTail = task.catch((): void => {
    });
    return task;
  }

  private static removeFormIds(context: Context, removedIds: string[]): Promise<void> {
    return FormStateSync.enqueueIdMutation(async (): Promise<void> => {
      const current = await FormStateSync.readFormRecords(context);
      const kept: FormRecord[] = [];
      for (const record of current) {
        if (!removedIds.includes(record.formId)) {
          kept.push(record);
        }
      }
      await FormStateSync.writeFormRecords(context, kept);
      FormStateSync.reconcileInfoRefresh(context, kept);
    });
  }

  /** Ability 销毁时停止刷新，避免后台残留定时器。 */
  static stopInfoRefresh(): void {
    if (FormStateSync.infoRefreshTimer >= 0) {
      clearInterval(FormStateSync.infoRefreshTimer);
      FormStateSync.infoRefreshTimer = -1;
    }
    FormStateSync.infoRefreshContext = null;
  }

  private static reconcileInfoRefresh(context: Context, records: FormRecord[]): void {
    let hasInfoForm = false;
    for (const record of records) {
      if (record.formName === INFO_FORM_NAME) {
        hasInfoForm = true;
        break;
      }
    }
    if (!hasInfoForm) {
      FormStateSync.stopInfoRefresh();
      return;
    }
    FormStateSync.infoRefreshContext = context;
    if (FormStateSync.infoRefreshTimer >= 0) {
      return;
    }
    FormStateSync.infoRefreshTimer = setInterval((): void => {
      const activeContext = FormStateSync.infoRefreshContext;
      if (activeContext === null) {
        return;
      }
      FormStateSync.refreshInfoForms(activeContext).catch((error: Error): void => {
        AppLogger.warn(TAG, `info refresh failed: ${error.message}`);
      });
    }, INFO_REFRESH_INTERVAL_MS);
  }

  private static async refreshInfoForms(context: Context): Promise<void> {
    const records = await FormStateSync.readFormRecords(context);
    const infoRecords: FormRecord[] = [];
    for (const record of records) {
      if (record.formName === INFO_FORM_NAME) {
        infoRecords.push(record);
      }
    }
    if (infoRecords.length === 0) {
      FormStateSync.stopInfoRefresh();
      return;
    }
    const calibrated = await FormStateSync.calibrate(context);
    const payload = await FormStateSync.withInfoMetrics(context, calibrated);
    const invalidIds: string[] = [];
    for (const record of infoRecords) {
      try {
        await FormStateSync.updateOne(record.formId, payload);
      } catch (error) {
        invalidIds.push(record.formId);
      }
    }
    if (invalidIds.length > 0) {
      await FormStateSync.removeFormIds(context, invalidIds);
    }
  }

  private static async formNameForId(context: Context, formId: string): Promise<string> {
    const records = await FormStateSync.readFormRecords(context);
    for (const record of records) {
      if (record.formId === formId) {
        return record.formName;
      }
    }
    return TOGGLE_FORM_NAME;
  }

  private static async withInfoMetrics(context: Context,
    source: FormStateSnapshot): Promise<FormStateSnapshot> {
    const snapshot = FormStateSync.copySnapshot(source);
    snapshot.memoryText = await FormInfoMetrics.memoryText();
    snapshot.publicIp = await FormInfoMetrics.cachedPublicIp(context);
    const orchestrator = ConnectionOrchestrator.instance();
    snapshot.uploadSpeedText = FormStateSync.formatSpeed(orchestrator.traffic.uploadSpeed);
    snapshot.downloadSpeedText = FormStateSync.formatSpeed(orchestrator.traffic.downloadSpeed);
    return snapshot;
  }

  private static formatSpeed(bytesPerSecond: number): string {
    if (!Number.isFinite(bytesPerSecond) || bytesPerSecond <= 0) {
      return '0 B/s';
    }
    if (bytesPerSecond < 1024) {
      return `${Math.round(bytesPerSecond)} B/s`;
    }
    if (bytesPerSecond < 1024 * 1024) {
      return `${(bytesPerSecond / 1024).toFixed(1)} KB/s`;
    }
    return `${(bytesPerSecond / (1024 * 1024)).toFixed(1)} MB/s`;
  }

  private static copySnapshot(source: FormStateSnapshot): FormStateSnapshot {
    const target = new FormStateSnapshot();
    target.stateCode = source.stateCode;
    target.stateLabel = source.stateLabel;
    target.nodeName = source.nodeName;
    target.actionLabel = source.actionLabel;
    target.busy = source.busy;
    target.memoryText = source.memoryText;
    target.publicIp = source.publicIp;
    target.uploadSpeedText = source.uploadSpeedText;
    target.downloadSpeedText = source.downloadSpeedText;
    target.accessibilityLabel = source.accessibilityLabel;
    return target;
  }

  private static normalizeFormName(formName: string): string {
    return formName === INFO_FORM_NAME ? INFO_FORM_NAME : TOGGLE_FORM_NAME;
  }

  private static async readFormRecords(context: Context): Promise<FormRecord[]> {
    const store = await preferences.getPreferences(context, { name: FORM_PREF });
    const raw = await store.get(FORM_RECORDS_KEY, '') as string;
    const records = FormStateSync.parseRecords(raw);
    if (records.length > 0 || raw.length > 0) {
      return records;
    }
    const legacyRaw = await store.get(FORM_IDS_KEY, '[]') as string;
    const legacyIds = FormStateSync.parseIds(legacyRaw);
    for (const id of legacyIds) {
      const record = new FormRecord();
      record.formId = id;
      records.push(record);
    }
    return records;
  }

  private static async writeFormRecords(context: Context, records: FormRecord[]): Promise<void> {
    const store = await preferences.getPreferences(context, { name: FORM_PREF });
    await store.put(FORM_RECORDS_KEY, JSON.stringify(records));
    const ids: string[] = records.map((record: FormRecord): string => record.formId);
    await store.put(FORM_IDS_KEY, JSON.stringify(ids));
    await store.flush();
  }

  private static parseRecords(raw: string): FormRecord[] {
    const result: FormRecord[] = [];
    if (raw.length === 0) {
      return result;
    }
    try {
      const values = JSON.parse(raw) as FormRecord[];
      for (const value of values) {
        if (typeof value.formId === 'string' && value.formId.length > 0) {
          const record = new FormRecord();
          record.formId = value.formId;
          record.formName = FormStateSync.normalizeFormName(value.formName);
          result.push(record);
        }
      }
    } catch (error) {
      AppLogger.warn(TAG, 'form record list is invalid; reset to empty');
    }
    return result;
  }

  private static async readFormIds(context: Context): Promise<string[]> {
    const store = await preferences.getPreferences(context, FORM_PREF);
    const raw = await store.get(FORM_IDS_KEY, '[]') as string;
    return FormStateSync.parseIds(raw);
  }

  private static async writeFormIds(context: Context, ids: string[]): Promise<void> {
    const store = await preferences.getPreferences(context, FORM_PREF);
    await store.put(FORM_IDS_KEY, JSON.stringify(ids));
    await store.flush();
  }

  private static parseIds(raw: string): string[] {
    const result: string[] = [];
    try {
      const values = JSON.parse(raw) as string[];
      if (Array.isArray(values)) {
        for (const value of values) {
          if (typeof value === 'string' && value.length > 0 && !result.includes(value)) {
            result.push(value);
          }
        }
      }
    } catch (error) {
      AppLogger.warn(TAG, 'form id list is invalid; reset to empty');
    }
    return result;
  }
}
