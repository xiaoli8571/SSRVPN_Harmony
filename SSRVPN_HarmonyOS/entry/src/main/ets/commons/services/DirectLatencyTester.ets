/**
 * 直连延迟测试（未连接 VPN 时使用）
 *
 * 背景: Clash API 的 /proxies/{name}/delay 由 VPN 扩展进程里的内核承载,
 * 未连接时 127.0.0.1:9090 不存在 —— 此前未连接点"测全部"全部超时的根因。
 * 方案(对齐 NekoBox/Hey 的离线测速思路): UI 进程直接对节点服务器
 * server:port 发起 TCP 连接, 用握手往返时间近似延迟。TCP 握手可达 ≈
 * 节点可用; 虽然不经过代理协议协商, 但足以区分"服务器活着/已被墙"。
 */
import { socket } from '@kit.NetworkKit';
import { ProxyNode } from '../models/ProxyNode';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'DirectLatencyTester';
const TCP_TIMEOUT_MS = 4000;

export class DirectLatencyTester {
  /** 直连测试单个节点: 返回 TCP 握手毫秒数, 失败返回 -1 */
  static async testNode(node: ProxyNode): Promise<number> {
    if (node.server.length === 0 || node.port <= 0 || node.port >= 65536) {
      return -1;
    }
    const start = Date.now();
    let tcpSocket: socket.TCPSocket | null = null;
    try {
      tcpSocket = socket.constructTCPSocketInstance();
      await tcpSocket.connect({
        address: { address: node.server, port: node.port, family: 1 },
        timeout: TCP_TIMEOUT_MS
      });
      const elapsed = Date.now() - start;
      try {
        tcpSocket.close();
      } catch (e) {
        // 关闭失败不影响结果
      }
      return elapsed;
    } catch (e) {
      if (tcpSocket !== null) {
        try {
          tcpSocket.close();
        } catch (e2) {
          // ignore
        }
      }
      return -1;
    }
  }

  /** 批量直连测试: 依次测(避免并发打爆), 每个结果通过回调即时上报 */
  static async testAll(nodes: ProxyNode[],
    onResult: (node: ProxyNode, delayMs: number) => void): Promise<void> {
    for (const node of nodes) {
      const delay = await DirectLatencyTester.testNode(node);
      onResult(node, delay);
    }
  }
}
