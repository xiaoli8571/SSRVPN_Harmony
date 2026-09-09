/**
 * 后台快捷连接/断开入口（桌面图标长按快捷方式、服务卡片 message 共用）。
 *
 * 与 HomePage 手动按钮走同一 orchestrator 单例与配置管线，但不依赖任何 UI 页面：
 * QuickToggleAbility（无界面宿主）与 EntryFormAbility（卡片进程回调）直接调用。
 * 返回语义串供调用方更新卡片/日志：
 *   'on' 已发起并连接成功 / 'off' 已断开 / 'already' 隧道已存活无需动作
 *   / 'no_node' 无可用节点 / 'failed' 连接失败
 */
import { SettingsService } from './SettingsService';
import { SubscriptionService } from './SubscriptionService';
import { ConnectionOrchestrator } from './ConnectionOrchestrator';
import { FormStateSync } from './FormStateSync';
import { ProxyNode } from '../models/ProxyNode';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'VpnQuickStart';

export class VpnQuickStart {
  static async run(mode: string, context: Context): Promise<string> {
    try {
      await SettingsService.init(context);
      const subs = new SubscriptionService();
      await subs.init(context);
      const settings = await SettingsService.load();
      const orch = ConnectionOrchestrator.instance();
      orch.init(context);

      const alive = orch.isTunnelAlive();
      if (mode === 'toggle') {
        if (alive) {
          await orch.disconnect();
          FormStateSync.pushState(context, '未连接');
          return 'off';
        }
      } else if (alive) {
        // start 模式且隧道已活着: 什么都不做(幂等), 顺手把卡片状态校准
        FormStateSync.pushState(context, '已连接');
        return 'already';
      }

      const node: ProxyNode | null = subs.findNode(settings.preferredNodeId)
        ?? (subs.nodes.length > 0 ? subs.nodes[0] : null);
      if (node === null) {
        AppLogger.warn(TAG, 'quick start: no node available');
        return 'no_node';
      }
      const ok = await orch.connect(node, subs);
      AppLogger.info(TAG, `quick ${mode} => ${ok ? 'on' : 'failed'} (node=${node.name})`);
      FormStateSync.pushState(context, ok ? '已连接' : '连接失败');
      return ok ? 'on' : 'failed';
    } catch (e) {
      AppLogger.error(TAG, `quick start failed: ${e instanceof Error ? e.message : String(e)}`);
      return 'failed';
    }
  }
}
