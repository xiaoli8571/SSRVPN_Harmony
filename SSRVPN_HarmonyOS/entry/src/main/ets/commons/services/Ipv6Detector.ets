/**
 * IPv6 环境探测器 —— "IPv6 入站"功能的环境检查（对齐 FlClash 等主流客户端语义）:
 * 当前网络有 IPv6 连通性 → 开双栈; 没有 → 自动绕过(IPv4-only, AAAA 返回空)。
 *
 * 探测方式: UDP socket bind('::') 后向公网 IPv6 地址 send 一个空报文 —— 与
 * ping6 的 sendto 语义一致: 无 IPv6 路由时内核立刻返回 Network unreachable,
 * 有路由则 send 成功(不等待回包)。必须在 VPN 隧道建立之前探测, 否则 ::/0
 * 指向隧道自身, 结果恒为"有"。
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'Ipv6Detector';

/** 探测目标: Google DNS / Cloudflare DNS 的 IPv6 地址 */
const PROBE_TARGETS: string[] = ['2001:4860:4860::8888', '2606:4700:4700::1111'];
/** 单次探测超时(ms): 路由存在但链路异常时防挂死 */
const PROBE_TIMEOUT_MS: number = 1500;

export class Ipv6Detector {
  private static probeOnce(ip: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let done = false;
      const finish = (v: boolean): void => {
        if (done) {
          return;
        }
        done = true;
        resolve(v);
      };
      const udp = socket.constructUDPSocketInstance();
      const timer = setTimeout(() => {
        udp.close().catch(() => {});
        finish(false);
      }, PROBE_TIMEOUT_MS);
      const encoder = util.TextEncoder.create('utf-8');
      udp.bind({ address: '::', port: 0, family: 2 })
        .then(() => udp.send({
          data: encoder.encodeInto('ssrvpn-probe'),
          address: { address: ip, port: 53, family: 2 }
        }))
        .then(() => {
          clearTimeout(timer);
          udp.close().catch(() => {});
          finish(true);
        })
        .catch(() => {
          clearTimeout(timer);
          udp.close().catch(() => {});
          finish(false);
        });
    });
  }

  /** 当前物理网络是否具备 IPv6 连通性 */
  static async hasIPv6(): Promise<boolean> {
    for (const ip of PROBE_TARGETS) {
      const ok = await Ipv6Detector.probeOnce(ip);
      if (ok) {
        AppLogger.info(TAG, `probe ${ip} ok -> IPv6 available`);
        return true;
      }
    }
    AppLogger.info(TAG, 'no IPv6 connectivity -> inbound IPv6 auto-bypass (IPv4-only)');
    return false;
  }
}
