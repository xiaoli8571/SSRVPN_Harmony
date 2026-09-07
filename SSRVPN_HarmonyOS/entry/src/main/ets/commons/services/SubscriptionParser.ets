/**
 * 订阅解析器（统一入口）
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/subscription_parser.dart
 *                subscription_parser_base64_part.dart
 *                subscription_parser_naming_part.dart
 *                subscription_parser_yaml_part.dart
 *
 * 支持：ssr:// / ss:// / vless:// / vmess:// / trojan:// 单链接、Base64 批量列表、Clash YAML proxies。
 */
import { ProxyNode, ProxyNodeType, SsrCodec } from '../models/ProxyNode';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'SubscriptionParser';

export class SubscriptionParser {
  private static isProxyUri(trimmed: string): boolean {
    return trimmed.startsWith('ssr://') || trimmed.startsWith('ss://')
      || trimmed.startsWith('vless://') || trimmed.startsWith('vmess://')
      || trimmed.startsWith('trojan://');
  }
  /**
   * 解析订阅文本，返回节点列表。
   * 顺序与 upstream 一致：先按行找 ssr:///ss:// 链接 → 整体 base64 解码后再找 → Clash YAML。
   */
  static parse(text: string, subscriptionId: string): ProxyNode[] {
    const nodes: ProxyNode[] = [];
    const seen = new Set<string>();
    let counter = 0;

    const add = (node: ProxyNode | null): void => {
      if (node === null) {
        return;
      }
      const key = `${node.server}:${node.port}:${node.proxyType.length > 0 ? node.proxyType : node.type}:${node.rawUri}`;
      if (seen.has(key)) {
        return;
      }
      seen.add(key);
      node.name = SubscriptionParser.dedupName(nodes, node.name);
      nodes.push(node);
    };

    // 1) 明文链接逐行解析
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (SubscriptionParser.isProxyUri(trimmed)) {
        add(ProxyNode.fromUri(trimmed, subscriptionId, `${subscriptionId}-${counter++}`));
      }
    }

    // 2) 整体 Base64 解码后再解析（对应 subscription_parser_base64_part）
    if (nodes.length === 0) {
      const decoded = SsrCodec.decodeBase64Url(text.replace(/\s+/g, ''));
      if (decoded.length > 0 && decoded.includes('://')) {
        for (const line of decoded.split(/\r?\n/)) {
          const trimmed = line.trim();
          if (SubscriptionParser.isProxyUri(trimmed)) {
            add(ProxyNode.fromUri(trimmed, subscriptionId, `${subscriptionId}-${counter++}`));
          }
        }
      }
    }

    // 3) Clash YAML proxies 提取（对应 subscription_parser_yaml_part；完整 YAML 语义由 ClashConfigGenerator 的解析支持）
    if (nodes.length === 0) {
      const yamlNodes = SubscriptionParser.parseClashYaml(text, subscriptionId, counter);
      for (const n of yamlNodes) {
        add(n);
      }
    }

    AppLogger.info(TAG, `parsed ${nodes.length} nodes for subscription ${subscriptionId}`);
    return nodes;
  }

  /** 节点重名规整（对应 subscription_parser_naming_part）：重名追加序号 */
  static dedupName(existing: ProxyNode[], name: string): string {
    const base = name.length > 0 ? name : 'node';
    let finalName = base;
    let i = 2;
    const names = new Set<string>(existing.map((n) => n.name));
    while (names.has(finalName)) {
      finalName = `${base} ${i++}`;
    }
    return finalName;
  }

  /**
   * 从 Clash YAML 提取 proxies（轻量行级解析，覆盖 upstream 常见订阅格式：
   * `- {name: x, type: ss, server: y, port: 1, cipher: z, password: w}` 以及块列表两种写法）
   */
  static parseClashYaml(text: string, subscriptionId: string, startCounter: number): ProxyNode[] {
    const out: ProxyNode[] = [];
    let counter = startCounter;
    const lines = text.split(/\r?\n/);
    let inProxies = false;
    for (const raw of lines) {
      const line = raw.trim();
      if (line === 'proxies:') {
        inProxies = true;
        continue;
      }
      if (!inProxies) {
        continue;
      }
      if (line.length > 0 && !line.startsWith('-') && !line.startsWith('#') && !raw.startsWith(' ')) {
        inProxies = false;
        continue;
      }
      if (!line.startsWith('-')) {
        continue;
      }
      const entry = line.substring(1).trim();
      const node = new ProxyNode();
      node.id = `${subscriptionId}-y${counter++}`;
      node.subscriptionId = subscriptionId;
      const type = SubscriptionParser.yamlValue(entry, 'type') ?? '';
      if (type.length === 0) {
        continue;
      }
      node.proxyType = type;
      if (type === 'ssr') {
        node.type = ProxyNodeType.SSR;
      } else if (type === 'ss') {
        node.type = ProxyNodeType.SS;
      }
      node.name = SubscriptionParser.yamlValue(entry, 'name') ?? '';
      node.server = SubscriptionParser.yamlValue(entry, 'server') ?? '';
      node.port = parseInt(SubscriptionParser.yamlValue(entry, 'port') ?? '0');
      node.method = SubscriptionParser.yamlValue(entry, 'cipher') ?? '';
      node.password = (SubscriptionParser.yamlValue(entry, 'password') ?? '').replace(/['"]/g, '');
      node.protocol = (SubscriptionParser.yamlValue(entry, 'protocol') ?? '').replace(/['"]/g, '');
      node.obfs = (SubscriptionParser.yamlValue(entry, 'obfs') ?? '').replace(/['"]/g, '');
      // 非块级写法（单行 flow-map）时保留原始条目，配置生成阶段原样透传
      if (raw.trim().startsWith('- {') && raw.trim().endsWith('}')) {
        node.rawYaml = raw.trim();
      }
      if (node.server.length > 0 && node.port > 0) {
        out.push(node);
      }
    }
    return out;
  }

  /** 取 `key: value` 或 `key: 'value'` 的值（flow-map 与块写法通用） */
  static yamlValue(entry: string, key: string): string | null {
    const re = new RegExp(`${key}\\s*:\\s*([^,},]+?)(?=\\s*,|\\s*}|$)`);
    const m = entry.match(re);
    return m ? m[1].trim().replace(/^['"]|['"]$/g, '') : null;
  }
}
