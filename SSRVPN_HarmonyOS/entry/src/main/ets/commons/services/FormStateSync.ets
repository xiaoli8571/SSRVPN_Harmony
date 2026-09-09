/**
 * 桌面服务卡片状态广播：连接状态变化后，把最新状态文案写回本应用全部卡片。
 *
 * formProvider.getFormsInfo 不含 formId，无法枚举更新目标 —— 由
 * EntryFormAbility 在 onAddForm/onRemoveForm 时把 formId 登记到 preferences
 * （'ssrvpn_forms'/'form_ids'），这里读清单逐个 updateForm。
 * 任何失败静默吞掉（卡片已删/系统限制不影响主流程）。
 */
import { formBindingData, formProvider } from '@kit.FormKit';
import { preferences } from '@kit.ArkData';

const FORM_PREF = 'ssrvpn_forms';
const FORM_IDS_KEY = '***';

export class FormStateSync {
  /** EntryFormAbility 新增卡片时登记 */
  static async addFormId(context: Context, formId: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, FORM_PREF);
      const ids = FormStateSync.parseIds(await store.get(FORM_IDS_KEY, '[]') as string);
      if (!ids.includes(formId)) {
        ids.push(formId);
        await store.put(FORM_IDS_KEY, JSON.stringify(ids));
        await store.flush();
      }
    } catch (e) {
      // 登记失败不影响卡片添加
    }
  }

  /** EntryFormAbility 移除卡片时销账 */
  static async removeFormId(context: Context, formId: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, FORM_PREF);
      const ids = FormStateSync.parseIds(await store.get(FORM_IDS_KEY, '[]') as string)
        .filter((x) => x !== formId);
      await store.put(FORM_IDS_KEY, JSON.stringify(ids));
      await store.flush();
    } catch (e) {
      // ignore
    }
  }

  static pushState(context: Context, state: string): void {
    FormStateSync.pushStateAsync(context, state).catch(() => {
    });
  }

  private static async pushStateAsync(context: Context, state: string): Promise<void> {
    const store = await preferences.getPreferences(context, FORM_PREF);
    const ids = FormStateSync.parseIds(await store.get(FORM_IDS_KEY, '[]') as string);
    const data: Record<string, string> = { 'state': state };
    for (const id of ids) {
      formProvider.updateForm(id, formBindingData.createFormBindingData(data)).catch(() => {
        // 卡片已被移除: 顺手从清单剔除
        FormStateSync.removeFormId(context, id);
      });
    }
  }

  private static parseIds(raw: string): string[] {
    const out: string[] = [];
    try {
      const arr = JSON.parse(raw) as string[];
      if (Array.isArray(arr)) {
        for (const x of arr) {
          if (typeof x === 'string' && x.length > 0) {
            out.push(x);
          }
        }
      }
    } catch (e) {
      // 清单损坏按空处理
    }
    return out;
  }
}
