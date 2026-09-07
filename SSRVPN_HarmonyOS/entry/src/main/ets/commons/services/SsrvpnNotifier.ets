/**
 * 常驻通知（对应 upstream VpnNotificationSupport / NotificationUpdatePolicy）
 * 连接期间显示节点名与实时速率；每秒由编排器刷新。
 */
import { notificationManager } from '@kit.NotificationKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'SsrvpnNotifier';
const NOTIFICATION_ID = 1001;

export class SsrvpnNotifier {
  private static lastText: string = '';
  private static lastUpdateAt: number = 0;

  static async update(title: string, nodeLine: string, speedLine: string): Promise<void> {
    // 节流：内容未变化或距上次刷新不足 900ms 则跳过
    const text = `${nodeLine}\n${speedLine}`;
    const now = Date.now();
    if (text === SsrvpnNotifier.lastText && now - SsrvpnNotifier.lastUpdateAt < 900) {
      return;
    }
    SsrvpnNotifier.lastText = text;
    SsrvpnNotifier.lastUpdateAt = now;
    try {
      const contentBody: notificationManager.NotificationBasicContent = {
        title: title,
        text: speedLine,
        additionalText: nodeLine
      };
      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: contentBody
        },
        isOngoing: true,
        isUnremovable: true
      };
      await notificationManager.publish(request);
    } catch (e) {
      // 通知授权未开启等情况静默降级（不影响 VPN 功能）
      AppLogger.warn(TAG, `notify failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  static async cancel(): Promise<void> {
    try {
      await notificationManager.cancel(NOTIFICATION_ID);
      SsrvpnNotifier.lastText = '';
    } catch (e) {
      // 忽略
    }
  }
}
