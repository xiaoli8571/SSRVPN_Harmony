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
    mixedPort: number, apiPort: number, apiSecret: string, useGeoip: boolean = true,
    ipv6Enabled: boolean = false, proxyHosts: Record<string, string> = {},
    tunEnabled: boolean = true): string {
    const lines: string[] = [];

    lines.push('mixed-port: ' + mixedPort);
    lines.push('external-controller: 127.0.0.1:' + apiPort);
    lines.push('secret: "' + apiSecret + '"');
    // 代理模式（upstream settings.proxyMode）：rule=规则 / global=全局
    lines.push('mode: ' + (settings.proxyMode === 'global' ? 'global' : 'rule'));
    lines.push('log-level: info');
    // IPv6 入站(FlClash 常用功能): 按当前网络环境自动启用 —— 连接时由 Ipv6Detector
    // 探测, 有 IPv6 出口才开; 无 IPv6 环境自动绕过(纯 IPv4), 防止 IPv6-preferred
    // 应用(YouTube 等)被 fake-ip6 + ::/0 引上死路。
    lines.push('ipv6: ' + (ipv6Enabled ? 'true' : 'false'));
    lines.push('unified-delay: true');
    lines.push('tcp-concurrent: true');
    lines.push('');
    lines.push('dns:');
    lines.push('  enable: true');
    lines.push('  listen: 127.0.0.1:1053');
    // DNS 覆写(FlClash 常用功能, 默认常开不提供关闭): enable+fake-ip 接管全部解析,
    // 应用侧 DNS 设置被覆写为内核 fake-ip, 避免运营商 DNS 污染。
    // dns.ipv6=false 时 AAAA 直接返回空 = IPv6 解析绕过, 应用自动走 IPv4。
    lines.push('  ipv6: ' + (ipv6Enabled ? 'true' : 'false'));
    lines.push('  enhanced-mode: fake-ip');
    lines.push('  fake-ip-range: 198.18.0.1/16');
    if (ipv6Enabled) {
      lines.push('  fake-ip-range6: fc00::/71');
    }
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
    // headless 测速模式: tun.enable=false, 内核只开 mixed/API 端口, 不建隧道不碰 VPN 权限
    lines.push('  enable: ' + (tunEnabled ? 'true' : 'false'));
    lines.push('  stack: gvisor');  // fd 注入 + 沙箱无 iptables, 只有 gvisor 可用
    // DNS 覆写(TUN 层): 所有目标端口 53 的 DNS 请求一律劫持进内核解析。
    lines.push('  dns-hijack:');
    lines.push('    - any:53');
    lines.push('  auto-route: false');   // 路由由 VpnExtensionAbility 安装
    lines.push('  auto-detect-interface: false');
    lines.push('  mtu: 1400');          // 与 VpnConfig.mtu 一致(对齐 NekoBox)
    if (ipv6Enabled) {
      // IPv6 入站已启用: 与 VpnExtensionAbility 的 TUN_ADDRESS_V6/TUN_PREFIX_V6 严格一致
      lines.push("  inet6-address: ['fdfe:dcba:9876::1/126']");
    }
    lines.push('');
    // ── hosts: 代理服务器域名的防投毒固定解析(UI 进程 DoH 预解析结果) ──
    // 内核拨号代理服务器时直接命中这些真实 IP, 不再走运行期(可能被污染的)DNS。
    const normalizedHosts = new Map<string, string>();
    for (const rawHost of Object.keys(proxyHosts)) {
      const host = ClashConfigGenerator.normalizeDomain(rawHost);
      const address = proxyHosts[rawHost].trim();
      if (host.length === 0 || !ClashConfigGenerator.isValidIpAddress(address)) {
        continue;
      }
      normalizedHosts.set(host, address.toLowerCase());
    }
    if (normalizedHosts.size > 0) {
      lines.push('hosts:');
      for (const h of Array.from(normalizedHosts.keys()).sort()) {
        lines.push(`  "${ClashConfigGenerator.escapeYaml(h)}": "${ClashConfigGenerator.escapeYaml(normalizedHosts.get(h) ?? '')}"`);
      }
      lines.push('');
    }
    lines.push('proxies:');
    // 只从白名单结构化字段生成合法配置，任何协议均不透传 rawYaml。
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
    // 强制站点规则统一做域名规范化、格式验证和去重，避免规则/YAML 注入。
    const directSites = ClashConfigGenerator.normalizeDomains(settings.forceDirectSites);
    const proxySites = ClashConfigGenerator.normalizeDomains(settings.forceProxySites);
    for (const site of directSites) {
      lines.push(`  - DOMAIN-SUFFIX,${site},DIRECT`);
    }
    for (const site of proxySites) {
      // DIRECT 优先，避免同一域名生成互相冲突的规则。
      if (!directSites.includes(site)) {
        lines.push(`  - DOMAIN-SUFFIX,${site},PROXY`);
      }
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
    const proxyType = n.type === ProxyNodeType.SSR ? 'ssr'
      : (n.type === ProxyNodeType.SS ? 'ss' : n.proxyType.toLowerCase());
    if (proxyType !== 'ss' && proxyType !== 'ssr' && proxyType !== 'vless'
      && proxyType !== 'vmess' && proxyType !== 'trojan' && proxyType !== 'hysteria2') {
      return '';
    }
    const textValues: string[] = [n.name, n.server, n.password, n.method, n.protocol, n.protocolParam,
      n.obfs, n.obfsParam, n.uuid, n.network, n.servername, n.flow, n.clientFingerprint,
      n.realityPublicKey, n.realityShortId, n.wsPath, n.wsHost, n.grpcServiceName,
      n.hyUp, n.hyDown, n.alpnList];
    for (const value of textValues) {
      if (!ClashConfigGenerator.isSafeText(value)) {
        return '';
      }
    }
    if (n.name.length === 0 || n.server.length === 0 || n.port <= 0 || n.port > 65535) {
      return '';
    }
    if ((proxyType === 'ss' || proxyType === 'ssr')
      && (n.method.length === 0 || n.password.length === 0)) {
      return '';
    }
    if (proxyType === 'ssr' && (n.protocol.length === 0 || n.obfs.length === 0)) {
      return '';
    }
    if ((proxyType === 'vless' || proxyType === 'vmess') && n.uuid.length === 0) {
      return '';
    }
    if (proxyType === 'trojan' && n.password.length === 0) {
      return '';
    }
    if (proxyType === 'hysteria2' && n.password.length === 0) {
      return '';
    }
    if (n.alterId < 0 || !Number.isInteger(n.alterId)) {
      return '';
    }

    const q = (value: string): string => `"${ClashConfigGenerator.escapeYaml(value)}"`;
    const fields: string[] = [];
    fields.push(`name: ${q(n.name)}`);
    fields.push(`type: ${proxyType}`);
    fields.push(`server: ${q(n.server)}`);
    fields.push(`port: ${n.port}`);
    if (proxyType === 'ss' || proxyType === 'ssr' || proxyType === 'vmess') {
      fields.push(`cipher: ${q(n.method.length > 0 ? n.method : 'auto')}`);
    }
    if (proxyType === 'ss' || proxyType === 'ssr' || proxyType === 'trojan' || proxyType === 'hysteria2') {
      fields.push(`password: ${q(n.password)}`);
    }
    if (proxyType === 'ssr') {
      fields.push(`protocol: ${q(n.protocol)}`);
      fields.push(`protocol-param: ${q(n.protocolParam)}`);
      fields.push(`obfs: ${q(n.obfs)}`);
      fields.push(`obfs-param: ${q(n.obfsParam)}`);
    }
    if (proxyType === 'vless' || proxyType === 'vmess') {
      fields.push(`uuid: ${q(n.uuid)}`);
    }
    if (proxyType === 'vmess') {
      fields.push(`alterId: ${n.alterId}`);
    }
    if (n.udp) {
      fields.push('udp: true');
    }
    if (n.network.length > 0) {
      fields.push(`network: ${q(n.network)}`);
    }
    if (n.tls) {
      fields.push('tls: true');
    }
    if (n.servername.length > 0) {
      // hysteria2 的 SNI 键名是 sni（不支持 servername 键）
      fields.push(`${proxyType === 'hysteria2' ? 'sni' : 'servername'}: ${q(n.servername)}`);
    }
    if (n.skipCertVerify) {
      fields.push('skip-cert-verify: true');
    }
    if (n.flow.length > 0) {
      fields.push(`flow: ${q(n.flow)}`);
    }
    if (n.clientFingerprint.length > 0) {
      // hysteria2 的证书指纹(pinSHA256)键名是 fingerprint
      fields.push(`${proxyType === 'hysteria2' ? 'fingerprint' : 'client-fingerprint'}: ${q(n.clientFingerprint)}`);
    }
    if (proxyType === 'hysteria2') {
      if (n.obfs.length > 0) {
        fields.push(`obfs: ${q(n.obfs)}`);
      }
      if (n.obfsParam.length > 0) {
        fields.push(`obfs-password: ${q(n.obfsParam)}`);
      }
      if (n.hyUp.length > 0) {
        fields.push(`up: ${q(n.hyUp)}`);
      }
      if (n.hyDown.length > 0) {
        fields.push(`down: ${q(n.hyDown)}`);
      }
      if (n.alpnList.length > 0) {
        const items: string[] = [];
        for (const it of n.alpnList.split(',')) {
          if (it.length > 0) {
            items.push(q(it));
          }
        }
        if (items.length > 0) {
          fields.push(`alpn: [${items.join(', ')}]`);
        }
      }
    }
    if (n.realityPublicKey.length > 0 || n.realityShortId.length > 0) {
      const reality: string[] = [];
      if (n.realityPublicKey.length > 0) {
        reality.push(`public-key: ${q(n.realityPublicKey)}`);
      }
      if (n.realityShortId.length > 0) {
        reality.push(`short-id: ${q(n.realityShortId)}`);
      }
      fields.push(`reality-opts: {${reality.join(', ')}}`);
    }
    if (n.wsPath.length > 0 || n.wsHost.length > 0) {
      const ws: string[] = [];
      if (n.wsPath.length > 0) {
        ws.push(`path: ${q(n.wsPath)}`);
      }
      if (n.wsHost.length > 0) {
        ws.push(`headers: {Host: ${q(n.wsHost)}}`);
      }
      fields.push(`ws-opts: {${ws.join(', ')}}`);
    }
    if (n.grpcServiceName.length > 0) {
      fields.push(`grpc-opts: {grpc-service-name: ${q(n.grpcServiceName)}}`);
    }
    return `  - {${fields.join(', ')}}`;
  }

  /** 规范化域名列表并去重，忽略无法安全表达的条目。 */
  private static normalizeDomains(values: string[]): string[] {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const value of values) {
      const domain = ClashConfigGenerator.normalizeDomain(value);
      if (domain.length > 0 && !seen.has(domain)) {
        seen.add(domain);
        out.push(domain);
      }
    }
    return out;
  }

  /** 规范化并验证 hosts/规则使用的域名，拒绝通配符、换行和 YAML/规则元字符。 */
  private static normalizeDomain(value: string): string {
    let domain = value.trim().toLowerCase();
    while (domain.endsWith('.')) {
      domain = domain.substring(0, domain.length - 1);
    }
    if (domain.length === 0 || domain.length > 253 || domain.includes('\n') || domain.includes('\r')
      || domain.includes(',') || domain.includes(':') || domain.includes('#') || domain.includes('[')
      || domain.includes(']') || domain.includes('{') || domain.includes('}') || domain.includes('*')
      || domain.startsWith('.') || domain.endsWith('.') || domain.includes('..')) {
      return '';
    }
    const labels = domain.split('.');
    for (const label of labels) {
      if (label.length === 0 || label.length > 63 || label.startsWith('-') || label.endsWith('-')
        || !/^[a-z0-9-]+$/.test(label)) {
        return '';
      }
    }
    return domain;
  }

  /** hosts 值仅接受规范 IPv4 或无区域标识的 IPv6 字面量。 */
  private static isValidIpAddress(value: string): boolean {
    if (value.length === 0 || value.includes('\n') || value.includes('\r') || value.includes('%')
      || value.includes('#') || value.includes(',') || value.includes(' ') || value.includes('\t')) {
      return false;
    }
    const ipv4 = value.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
    if (ipv4 !== null) {
      for (let i = 1; i <= 4; i++) {
        const part = parseInt(ipv4[i]);
        if (part < 0 || part > 255) {
          return false;
        }
      }
      return true;
    }
    if (!/^[0-9a-fA-F:]+$/.test(value) || !value.includes(':')) {
      return false;
    }
    const pieces = value.split(':');
    if (pieces.length < 3 || pieces.length > 8) {
      return false;
    }
    let emptyRuns = 0;
    for (let i = 0; i < pieces.length; i++) {
      const piece = pieces[i];
      if (piece.length === 0) {
        if (i > 0 && pieces[i - 1].length === 0) {
          emptyRuns++;
        }
      } else if (piece.length > 4 || !/^[0-9a-fA-F]+$/.test(piece)) {
        return false;
      }
    }
    return emptyRuns <= 1;
  }

  private static isSafeText(value: string): boolean {
    return value.length <= 64 * 1024 && !value.includes('\n') && !value.includes('\r')
      && !value.includes('\u0000');
  }

  static escapeYaml(value: string): string {
    let out = '';
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      const code = value.charCodeAt(i);
      if (ch === '\\') {
        out += '\\\\';
      } else if (ch === '"') {
        out += '\\"';
      } else if (ch === '\t') {
        out += '\\t';
      } else if (code < 0x20 || code === 0x7f) {
        out += '?';
      } else {
        out += ch;
      }
    }
    return out;
  }

  /** 为端口冲突策略提供本实现使用的端口清单（对应 runtime_port_conflict_policy.dart） */
  static requiredPorts(): number[] {
    return [1053, 7890];
  }
}
