/**
 * 延迟测试状态（对应 upstream HomeLatencyController）
 * 键为节点名，值 -1/0 表示超时（NodeDisplayPolicy.isTimeoutLatency 语义）。
 *
 * 性能约束：批量测速时每个节点都会 set 一次。若每次都同步通知监听者，
 * 节点页会随每条结果重建整张列表（125 个节点即 125 次重排），把 UI 线程
 * 占满，用户观感就是「测速很慢」。这里把通知合并到最多每 200ms 一次：
 * 数值本身不变，仅把 UI 刷新从「每条一次」压成「每帧一次」。
 */
const NOTIFY_COALESCE_MS = 200;

export class LatencyController {
  private static map: Map<string, number> = new Map<string, number>();
  private static listeners: (() => void)[] = [];
  /** 待触发的合并通知定时器；-1 表示当前没有挂起的通知 */
  private static notifyTimer: number = -1;

  static latencyFor(nodeName: string): number | null {
    const v = LatencyController.map.get(nodeName);
    return v === undefined ? null : v;
  }

  static set(nodeName: string, latency: number): void {
    LatencyController.map.set(nodeName, latency);
    LatencyController.scheduleNotify();
  }

  static clearAll(): void {
    LatencyController.map.clear();
    LatencyController.scheduleNotify();
  }

  /**
   * 丢弃当前订阅已不存在节点的延迟，避免订阅反复刷新或换源后 Map 常驻增长。
   * 只有确实删除条目时才通知，因而可安全地在列表重建路径调用。
   */
  static retainOnly(nodeNames: string[]): void {
    const active = new Set<string>(nodeNames);
    let changed = false;
    for (const name of LatencyController.map.keys()) {
      if (!active.has(name)) {
        LatencyController.map.delete(name);
        changed = true;
      }
    }
    if (changed) {
      LatencyController.scheduleNotify();
    }
  }

  static addListener(listener: () => void): void {
    if (LatencyController.listeners.indexOf(listener) < 0) {
      LatencyController.listeners.push(listener);
    }
  }

  static removeListener(listener: () => void): void {
    const index = LatencyController.listeners.indexOf(listener);
    if (index >= 0) {
      LatencyController.listeners.splice(index, 1);
    }
  }

  /** 合并窗口内的通知调度：已有挂起定时器则不再排新的（O(1) 合并） */
  private static scheduleNotify(): void {
    if (LatencyController.notifyTimer >= 0) {
      return;
    }
    LatencyController.notifyTimer = setTimeout((): void => {
      LatencyController.notifyTimer = -1;
      LatencyController.notify();
    }, NOTIFY_COALESCE_MS);
  }

  /** 立即刷新（批次结束/进入页面恢复快照后调用，避免最后一批结果延迟 200ms 才显示） */
  static flushNow(): void {
    if (LatencyController.notifyTimer >= 0) {
      clearTimeout(LatencyController.notifyTimer);
      LatencyController.notifyTimer = -1;
    }
    LatencyController.notify();
  }

  /** 是否有挂起的合并通知（专项验证用） */
  static hasPendingNotify(): boolean {
    return LatencyController.notifyTimer >= 0;
  }

  static notify(): void {
    for (const l of LatencyController.listeners) {
      l();
    }
  }
}
