/**
 * 后台快捷连接/断开入口，桌面快捷方式与服务卡片共用。
 *
 * 入口使用进程级互斥。操作开始即向全部卡片发布忙碌态，完成后发布
 * 真实最终状态，避免多个卡片或连续点击重复拉起、停止 VPN。
 */
import { SettingsService } from './SettingsService';
import { SubscriptionService } from './SubscriptionService';
import { ConnectionOrchestrator, ConnState } from './ConnectionOrchestrator';
import { FormStateSync, FormStateSnapshot } from './FormStateSync';
import { ProxyNode } from '../models/ProxyNode';
import { AppLogger } from '../utils/AppLogger';
import { FormInfoMetrics } from './FormInfoMetrics';

const TAG = 'VpnQuickStart';

export class VpnQuickStart {
  /** 同一应用进程内所有快捷入口共享，防止多卡片并发执行切换。 */
  private static operation: Promise<string> | null = null;
  /** 连接尚未完成时收到的明确断开意图，不能被进程级互斥吞掉。 */
  private static pendingDisconnect: boolean = false;

  static isBusy(): boolean {
    return VpnQuickStart.operation !== null;
  }

  static run(mode: string, context: Context): Promise<string> {
    if (VpnQuickStart.operation !== null) {
      const orchestrator = ConnectionOrchestrator.instance();
      orchestrator.init(context);
      if (mode === 'toggle' && (orchestrator.state === ConnState.CONNECTING ||
        orchestrator.state === ConnState.RECOVERING || orchestrator.isTunnelAlive())) {
        VpnQuickStart.pendingDisconnect = true;
        orchestrator.requestDisconnect();
        AppLogger.info(TAG, 'disconnect requested while connect operation is in progress');
        return VpnQuickStart.operation.then((): string => 'off');
      }
      AppLogger.info(TAG, 'duplicate quick request joined existing operation');
      return VpnQuickStart.operation;
    }
    const task = VpnQuickStart.runExclusive(mode, context);
    VpnQuickStart.operation = task;
    task.finally((): void => {
      if (VpnQuickStart.operation === task) {
        VpnQuickStart.operation = null;
      }
    });
    return task;
  }

  private static async runExclusive(mode: string, context: Context): Promise<string> {
    let finalSnapshot: FormStateSnapshot = FormStateSync.disconnected();
    try {
      await SettingsService.init(context);
      const subscriptions = new SubscriptionService();
      await subscriptions.init(context);
      const settings = await SettingsService.load();
      const orchestrator = ConnectionOrchestrator.instance();
      orchestrator.init(context);

      const node: ProxyNode | null = subscriptions.findNode(settings.preferredNodeId)
        ?? (subscriptions.nodes.length > 0 ? subscriptions.nodes[0] : null);
      const nodeName = node === null ? '' : node.name;
      const alive = orchestrator.isTunnelAlive();

      if (mode === 'toggle' && alive) {
        await FormStateSync.publish(context, FormStateSync.disconnecting(nodeName));
        await orchestrator.disconnect();
        finalSnapshot = node === null ? FormStateSync.noNode() : FormStateSync.disconnected(nodeName);
        await FormStateSync.publish(context, finalSnapshot);
        FormInfoMetrics.refreshAfterVpnTransition(context);
        return 'off';
      }

      if (mode !== 'toggle' && alive) {
        finalSnapshot = FormStateSync.connected(nodeName);
        await FormStateSync.publish(context, finalSnapshot);
        return 'already';
      }

      if (node === null) {
        AppLogger.warn(TAG, 'quick start: no node available');
        finalSnapshot = FormStateSync.noNode();
        await FormStateSync.publish(context, finalSnapshot);
        return 'no_node';
      }

      await FormStateSync.publish(context, FormStateSync.connecting(node.name));
      const ok = await orchestrator.connect(node, subscriptions);
      if (VpnQuickStart.pendingDisconnect || orchestrator.isDisconnectRequested()) {
        VpnQuickStart.pendingDisconnect = false;
        await FormStateSync.publish(context, FormStateSync.disconnecting(node.name));
        await orchestrator.disconnect();
        finalSnapshot = FormStateSync.disconnected(node.name);
        await FormStateSync.publish(context, finalSnapshot);
        FormInfoMetrics.refreshAfterVpnTransition(context);
        return 'off';
      }
      finalSnapshot = ok ? FormStateSync.connected(node.name) : FormStateSync.failed(node.name);
      await FormStateSync.publish(context, finalSnapshot);
      if (ok) {
        FormInfoMetrics.refreshAfterVpnTransition(context);
      }
      AppLogger.info(TAG, `quick ${mode} => ${ok ? 'on' : 'failed'} (node=${node.name})`);
      return ok ? 'on' : 'failed';
    } catch (error) {
      AppLogger.error(TAG, `quick start failed: ${error instanceof Error ? error.message : String(error)}`);
      try {
        finalSnapshot = await FormStateSync.calibrate(context);
        if (finalSnapshot.busy) {
          finalSnapshot = FormStateSync.failed(finalSnapshot.nodeName);
        }
        await FormStateSync.publish(context, finalSnapshot);
      } catch (publishError) {
        AppLogger.warn(TAG, `failed to publish terminal state: ${publishError instanceof Error ? publishError.message : String(publishError)}`);
      }
      return 'failed';
    }
  }
}
