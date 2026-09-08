/**
 * 直连延迟测试（未连接 VPN 时使用）
 *
 * 背景: Clash API 的 /proxies/{name}/delay 由 VPN 扩展进程里的内核承载,
 * 未连接时 127.0.0.1:9090 不存在 —— 此前未连接点"测全部"全部超时的根因。
 * 方案(对齐 NekoBox/Hey 的离线测速思路): UI 进程直接对节点服务器
 * server:port 发起 TCP 连接, 用握手往返时间近似延迟。TCP 握手可达 ≈
 * 节点可用; 虽然不经过代理协议协商, 但足以区分"服务器活着/已被墙"。
 *
 * Hysteria2 例外(真机实测端口无 TCP 监听): 纯 QUIC/UDP 协议, 改用
 * "QUIC Initial 探测" —— 向服务器发一个结构正确的 v1 Initial 包, 任何
 * QUIC 栈都会回包(版本协商/连接关闭/握手继续), 收到即存活并得到 RTT。
 * 启用 obfs 混淆的 hy2 节点服务端要求首包已混淆, 伪造探测包会被丢弃
 * (测不出≠死了), 因此 obfs 节点仍返回 -2 未测试。
 */
import { socket } from '@kit.NetworkKit';
import { ProxyNode } from '../models/ProxyNode';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'DirectLatencyTester';
const TCP_TIMEOUT_MS = 4000;
const QUIC_TIMEOUT_MS = 2500;

export class DirectLatencyTester {
  /** 直连测试单个节点: TCP 毫秒数 / hy2 QUIC 探测毫秒数; 失败 -1; 无法离线探测 -2 */
  static async testNode(node: ProxyNode): Promise<number> {
    if (node.server.length === 0 || node.port <= 0 || node.port >= 65536) {
      return -1;
    }
    if (node.proxyType === 'hysteria2') {
      if (node.obfs.length > 0) {
        return -2;
      }
      return DirectLatencyTester.probeQuic(node);
    }
    return DirectLatencyTester.probeTcp(node);
  }

  /** TCP 握手探测（原实现） */
  private static async probeTcp(node: ProxyNode): Promise<number> {
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

  /**
   * 构造 1200 字节 QUIC 探测数据报（PC 对真实 hy2 服务器实测有效：GREASE 版本
   * 触发版本协商回包，RTT≈真实链路；短包和 v1 包会被服务端按反放大规则静默丢弃）：
   * 首字节 0xC0(long header+fixed+Initial) + 未知版本 0x0a0a0a0a + DCID(8B)
   * + SCID(0) + token(空) + 长度字段 + 0x00 填充至 1200B。
   */
  private static buildQuicInitial(): ArrayBuffer {
    const p = new Uint8Array(1200);
    p[0] = 0xC0;
    p[1] = 0x0a; p[2] = 0x0a; p[3] = 0x0a; p[4] = 0x0a; // 未知 GREASE 版本 → 服务端必回版本协商包
    p[5] = 0x08; // DCID len
    for (let i = 0; i < 8; i++) {
      p[6 + i] = 0x53;
    }
    p[14] = 0x00; // SCID len 0
    p[15] = 0x00; // token 长度 varint 0
    p[16] = 0x00;
    p[17] = 0x40; // Length varint（服务端先验版本，此字段宽松）
    p[18] = 0xB2;
    // 其余保持 0（Padding 帧）填满 1200B —— RFC 9000 要求 Initial 数据报 ≥1200B，
    // 否则 quic-go/hysteria 直接丢弃不回包（实测短包无响应）。
    return p.buffer;
  }

  /** hy2 QUIC 探测：收到任何 UDP 回包即计 RTT；超时 -1 */
  private static probeQuic(node: ProxyNode): Promise<number> {
    const udp = socket.constructUDPSocketInstance();
    const payload = DirectLatencyTester.buildQuicInitial();
    const start = Date.now();
    return new Promise<number>((resolve) => {
      let settled = false;
      let timerId = -1;
      const finish = (value: number): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId >= 0) {
          clearInterval(timerId);
        }
        try {
          udp.off('message');
        } catch (e) {
          // ignore
        }
        try {
          udp.close();
        } catch (e) {
          // ignore
        }
        resolve(value);
      };
      udp.on('message', () => {
        finish(Date.now() - start);
      });
      udp.bind({ address: '0.0.0.0', port: 0, family: 1 }).then(() => {
        udp.send({
          data: payload,
          address: { address: node.server, port: node.port, family: 1 }
        } as socket.UDPSendOptions).catch(() => {
          finish(-1);
        });
      }).catch(() => {
        finish(-1);
      });
      timerId = setInterval(() => {
        if (Date.now() - start >= QUIC_TIMEOUT_MS) {
          finish(-1);
        }
      }, 150);
    });
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
