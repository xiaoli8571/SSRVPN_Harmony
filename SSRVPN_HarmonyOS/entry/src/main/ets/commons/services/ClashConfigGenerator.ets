/**
 * Clash / Mihomo 配置生成器
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/clash_config_generator.dart
 *
 * 关键约束（与 upstream 行为一致）：
 * - IPv4-only：DNS 不解析 AAAA，ipv6: false
 * - external-controller 仅绑定 127.0.0.1，secret 由调用方注入
 * - TUN 通过 VpnExtensionAbility 的 fd 注入，配置仅声明 tun.enable
 * - 国内直连规则 + 强制代理站点规则
 */
import { ProxyNode, ProxyNodeType } from '../models/ProxyNode';
import { AppSettings } from '../models/AppSettings';

export class ClashConfigGenerator {
  static generate(selectedNode: ProxyNode, allNodes: ProxyNode[], settings: AppSettings,
    mixedPort: number, apiPort: number, apiSecret: string, useGeoip: boolean = true): string {
    const lines: string[] = [];

    lines.push('mixed-port: ' + mixedPort);
    lines.push('external-controller: 127.0.0.1:' + apiPort);
    lines.push('secret: "' + apiSecret + '"');
    // 代理模式（upstream settings.proxyMode）：rule=规则 / global=全局
    lines.push('mode: ' + (settings.proxyMode === 'global' ? 'global' : 'rule'));
    lines.push('log-level: info');
    // IPv6 入站(FlClash 常用功能, 默认常开不提供关闭): 内核处理 IPv6 流量,
    // TUN 配 fdfe:dcba:9876::1/126 + VpnConfig ::/0 路由, 与 IPv4 行为一致。
    lines.push('ipv6: true');
    lines.push('unified-delay: true');
    lines.push('tcp-concurrent: true');
    lines.push('');
    lines.push('dns:');
    lines.push('  enable: true');
    lines.push('  listen: 127.0.0.1:1053');
    // DNS 覆写(FlClash 常用功能, 默认常开不提供关闭): enable+fake-ip 接管全部解析,
    // 应用侧 DNS 设置被覆写为内核 fake-ip, 避免运营商 DNS 污染。
    lines.push('  ipv6: true');
    lines.push('  enhanced-mode: fake-ip');
    lines.push('  fake-ip-range: 198.18.0.1/16');
    lines.push('  fake-ip-range6: fc00::/71');
    // DNS 上游必须用裸 IP UDP 直连(不走代理不劫持): DoH(域名)会引发解析死锁——
    // 解析 DoH 域名 → DoH 请求 → 又需要域名 → 回环超时(真机 core.log 实证)。
    lines.push('  default-nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 119.29.29.29');
    lines.push('  nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 119.29.29.29');
    // 代理服务器域名的专用解析: 不走 fake-ip(否则内核拿 198.18.x.x 假地址拨号
    // 代理服务器, 全部 i/o timeout —— 真机 core.log 实证), 用真实 DNS 直出。
    lines.push('  proxy-server-nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 119.29.29.29');
    lines.push('');
    lines.push('tun:');
    lines.push('  enable: true');
    lines.push('  stack: gvisor');  // fd 注入 + 沙箱无 iptables, 只有 gvisor 可用
    // DNS 覆写(TUN 层): 所有目标端口 53 的 DNS 请求一律劫持进内核解析。
    lines.push('  dns-hijack:');
    lines.push('    - any:53');
    lines.push('  auto-route: false');   // 路由由 VpnExtensionAbility 安装
    lines.push('  auto-detect-interface: false');
    lines.push('  mtu: 1400');          // 与 VpnConfig.mtu 一致(对齐 NekoBox)
    // IPv6 入站: 与 VpnExtensionAbility 的 TUN_ADDRESS_V6/TUN_PREFIX_V6 严格一致
    lines.push("  inet6-address: ['fdfe:dcba:9876::1/126']");
    lines.push('');
    lines.push('proxies:');
    // 只输出能生成合法配置的节点（rawYaml 透传或 ss/ssr 字段完整）
    const validNodes: ProxyNode[] = [];
    for (const n of allNodes) {
      if (ClashConfigGenerator.proxyYamlLine(n).length > 0) {
        validNodes.push(n);
      }
    }
    if (validNodes.length === 0) {
      // 零有效节点时生成空 proxies + 空组会让内核解析失败，直接抛出可读错误
      throw new Error('没有可用的节点配置：请到「订阅」页刷新订阅后再连接');
    }
    for (const n of validNodes) {
      lines.push(ClashConfigGenerator.proxyYamlLine(n));
    }
    const groupSelected: ProxyNode = validNodes.includes(selectedNode) ? selectedNode : validNodes[0];
    lines.push('');
    lines.push('proxy-groups:');
    lines.push('  - name: "PROXY"');
    lines.push('    type: select');
    lines.push('    proxies:');
    lines.push(`      - "${ClashConfigGenerator.escapeYaml(groupSelected.name)}"`);
    for (const n of validNodes) {
      if (n.id !== groupSelected.id) {
        lines.push(`      - "${ClashConfigGenerator.escapeYaml(n.name)}"`);
      }
    }
    lines.push('');
    lines.push('rules:');
    // 强制直连站点（用户指定, 始终 DIRECT）
    for (const site of settings.forceDirectSites) {
      lines.push(`  - DOMAIN-SUFFIX,${site},DIRECT`);
    }
    // 强制代理站点（force_proxy_site_policy）
    for (const site of settings.forceProxySites) {
      lines.push(`  - DOMAIN-SUFFIX,${site},PROXY`);
    }
    // 国内直连：GEOIP 需要 geoip.metadb（内核 home 目录）; 缺失时降级跳过,
    // 否则 config.Parse 阶段就会联网下载 MMDB, 国内网络不可达直接导致启动失败。
    // DOMAIN-SUFFIX,cn 直连不受影响, MMDB 由编排器后台补齐后下次连接生效。
    if (useGeoip) {
      lines.push('  - GEOIP,CN,DIRECT');
    }
    lines.push('  - DOMAIN-SUFFIX,cn,DIRECT');
    // 兜底规则: 上面的国内规则已放行国内流量, 剩余(YouTube/Google 等国外站点)
    // 必须走代理。此前 bypassDomesticApps=true 会生成 MATCH,DIRECT, 导致
    // 国外流量也直连、无法访问被墙站点(真机 core.log: youtube:443 using DIRECT)。
    // bypassDomesticApps 的语义收敛为"国内直连分流是否启用"(见上方 GEOIP/cn 规则),
    // 不再影响兜底 —— 兜底永远是 PROXY, 否则 VPN 没有意义。
    lines.push('  - MATCH,PROXY');
    return lines.join('\n') + '\n';
  }

  static proxyYamlLine(n: ProxyNode): string {
    // 优先透传原始 YAML 条目（vmess/vless/trojan 等完整字段），仅同步节点名
    if (n.rawYaml.length > 0) {
      return ClashConfigGenerator.emitRawProxy(n.rawYaml, n.name);
    }
    if (n.type === ProxyNodeType.SSR) {
      if (n.method.length === 0 || n.password.length === 0 || n.server.length === 0 || n.port <= 0) {
        return '';
      }
      return `  - {name: "${ClashConfigGenerator.escapeYaml(n.name)}", type: ssr, server: ${n.server}, port: ${n.port}, `
        + `cipher: ${n.method}, password: "${ClashConfigGenerator.escapeYaml(n.password)}", `
        + `protocol: ${n.protocol}, protocol-param: "${ClashConfigGenerator.escapeYaml(n.protocolParam)}", obfs: ${n.obfs}, obfs-param: "${ClashConfigGenerator.escapeYaml(n.obfsParam)}"}`;
    }
    if (n.type === ProxyNodeType.SS) {
      if (n.method.length === 0 || n.password.length === 0 || n.server.length === 0 || n.port <= 0) {
        return '';
      }
      return `  - {name: "${ClashConfigGenerator.escapeYaml(n.name)}", type: ss, server: ${n.server}, port: ${n.port}, `
        + `cipher: ${n.method}, password: "${ClashConfigGenerator.escapeYaml(n.password)}"}`;
    }
    // 无 rawYaml 的非 ss/ssr 节点无法生成合法配置，跳过（避免内核配置解析失败）
    return '';
  }

  /**
   * 透传原始 proxies 条目并同步节点名：
   * 条目首行形如 `  - {name: x, ...}` 或 `  - name: x`，将 name 值替换为当前节点名
   * （合并引擎可能为重名节点追加 "(n)" 后缀，需保证 group 引用与条目名一致）。
   */
  static emitRawProxy(rawYaml: string, nodeName: string): string {
    const outLines: string[] = [];
    const rawLines = rawYaml.split('\n');
    for (let i = 0; i < rawLines.length; i++) {
      let line = rawLines[i];
      if (i === 0) {
        const re = /^(\s*-\s*\{?\s*name\s*:\s*)("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^,}\n]+)/;
        if (re.test(line)) {
          line = line.replace(re, `$1"${ClashConfigGenerator.escapeYaml(nodeName)}"`);
        }
      }
      outLines.push(line.startsWith('  ') ? line : `  ${line.trimStart()}`);
    }
    return outLines.join('\n');
  }

  static escapeYaml(value: string): string {
    return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  }

  /** 为端口冲突策略提供本实现使用的端口清单（对应 runtime_port_conflict_policy.dart） */
  static requiredPorts(): number[] {
    return [1053, 7890];
  }
}
