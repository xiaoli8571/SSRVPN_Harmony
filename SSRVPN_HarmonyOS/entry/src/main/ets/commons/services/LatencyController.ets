/**
 * 延迟测试状态（对应 upstream HomeLatencyController）
 * 键为节点名，值 -1/0 表示超时（NodeDisplayPolicy.isTimeoutLatency 语义）。
 */
export class LatencyController {
  private static map: Map<string, number> = new Map<string, number>();
  private static listeners: (() => void)[] = [];

  static latencyFor(nodeName: string): number | null {
    const v = LatencyController.map.get(nodeName);
    return v === undefined ? null : v;
  }

  static set(nodeName: string, latency: number): void {
    LatencyController.map.set(nodeName, latency);
    LatencyController.notify();
  }

  static clearAll(): void {
    LatencyController.map.clear();
    LatencyController.notify();
  }

  static addListener(listener: () => void): void {
    LatencyController.listeners.push(listener);
  }

  static notify(): void {
    for (const l of LatencyController.listeners) {
      l();
    }
  }
}
