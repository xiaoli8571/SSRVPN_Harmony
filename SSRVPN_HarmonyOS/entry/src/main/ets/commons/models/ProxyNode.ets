/**
 * 数据模型：代理节点
 * 移植自 upstream: packages/ssrvpn_shared/lib/models/proxy_node.dart
 */
import { util } from '@kit.ArkTS';

export enum ProxyNodeType {
  SSR = 'ssr',
  SS = 'ss',
  UNKNOWN = 'unknown'
}

export class ProxyNode {
  id: string = '';
  subscriptionId: string = '';
  /** 订阅中的原始节点名，用于代理组成员稳定解析；显示名加前缀或重名后缀时保持不变。 */
  originalName: string = '';
  name: string = '';
  server: string = '';
  port: number = 0;
  password: string = '';
  method: string = '';
  protocol: string = '';
  protocolParam: string = '';
  obfs: string = '';
  obfsParam: string = '';
  type: ProxyNodeType = ProxyNodeType.UNKNOWN;
  /** 真实代理类型字符串（vless/vmess/trojan/ss/ssr），用于展示与安全配置生成。 */
  proxyType: string = '';
  /** 现代协议白名单结构化字段。rawYaml 仅为旧存储兼容占位，禁止信任或输出。 */
  uuid: string = '';
  alterId: number = 0;
  udp: boolean = false;
  network: string = '';
  tls: boolean = false;
  servername: string = '';
  skipCertVerify: boolean = false;
  flow: string = '';
  /**
   * uTLS 指纹（mihomo 键 `client-fingerprint`，链接参数 `fp`，默认 chrome）。
   * ⚠ 与 certFingerprint **是两个不同的字段**，不可合并（曾经合并过，见下）。
   */
  clientFingerprint: string = '';
  /**
   * 证书指纹 pinSHA256（mihomo 键 `fingerprint`，链接参数 `pcs`/`pinSHA256`）。
   *
   * 为什么必须与 clientFingerprint 分开：mihomo 里
   *   `client-fingerprint` = uTLS 指纹（TLS 客户端伪装）
   *   `fingerprint`        = 证书指纹 pinSHA256（校验对端证书）
   * 是**语义完全不同的两个键**（见 mihomo common/convert/v.go：`fp`→client-fingerprint、
   * `pcs`→fingerprint）。此前两者共用一个槽位，于是 hysteria2 节点若同时带
   * `client-fingerprint` 与 `fingerprint`，前者会覆盖后者并被当成 pin 回写成
   * `fingerprint: chrome` —— 既丢了真正的 pin，又给内核一个非法的 pin 值。
   */
  certFingerprint: string = '';
  realityPublicKey: string = '';
  realityShortId: string = '';
  wsPath: string = '';
  wsHost: string = '';
  grpcServiceName: string = '';
  /** Hysteria2 (QUIC) 专属：带宽 up/down (Mbps)、口令混淆、ALPN。
   *  复用字段: password=认证口令, servername=sni, skipCertVerify=insecure,
   *  obfs=salamander/gecko, obfsParam=obfs-password, certFingerprint=pinSHA256。 */
  hyUp: string = '';
  hyDown: string = '';
  alpnList: string = '';
  /** 结构化槽位之外的额外 mihomo 键值(JSON 数组: [[key, value], ...])，生成配置时原样回写 */
  extraOpts: string = '';
  rawYaml: string = '';
  /**
   * 去凭据、去 name 的原始节点 flow-map 逐字模板（YamlMerger 构造）。
   * 与 rawYaml 不同：rawYaml 是旧存储占位（禁止输出），rawTemplate 已剔除
   * name/uuid/password/protocol-param/obfs-* 等，不含任何明文凭据，可安全
   * 持久化并在配置生成时原样回写（生成端再注入 name 与加密层回填的凭据）。
   */
  rawTemplate: string = '';
  rawUri: string = '';
  groupName: string = '';

  /** 已实现解析器的 URI scheme 注册表（与主流 Clash 客户端同构：认得的 scheme 逐个分发） */
  private static readonly URI_CODECS: Set<string> = new Set<string>([
    'ssr', 'ss', 'vless', 'vmess', 'trojan', 'hysteria2', 'hy2', 'tuic', 'anytls', 'hysteria',
    'wireguard'
  ]);

  /** scheme 是否有对应解析器（false = 未识别 scheme，由调用方计 unsupported 诊断） */
  static hasUriCodec(scheme: string): boolean {
    return ProxyNode.URI_CODECS.has(scheme.trim().toLowerCase());
  }

  static fromUri(uri: string, subscriptionId: string, id: string): ProxyNode | null {
    const trimmed = uri.trim();
    const schemeMatch = trimmed.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\//);
    if (schemeMatch === null) {
      return null;
    }
    const scheme = schemeMatch[1].toLowerCase();
    if (!ProxyNode.URI_CODECS.has(scheme)) {
      return null;
    }
    // 各解析器按自身 scheme 长度截头，保持与既有实现一致
    if (scheme === 'ssr') {
      return SsrCodec.parseSsr(trimmed.substring(6), subscriptionId, id);
    }
    if (scheme === 'ss') {
      return SsrCodec.parseSs(trimmed.substring(5), subscriptionId, id);
    }
    if (scheme === 'vless') {
      return ModernUriCodec.parseVless(trimmed.substring(8), subscriptionId, id);
    }
    if (scheme === 'vmess') {
      return ModernUriCodec.parseVmess(trimmed.substring(8), subscriptionId, id);
    }
    if (scheme === 'trojan') {
      return ModernUriCodec.parseTrojan(trimmed.substring(9), subscriptionId, id);
    }
    if (scheme === 'hysteria2') {
      return ModernUriCodec.parseHysteria2(trimmed.substring(12), subscriptionId, id);
    }
    if (scheme === 'hy2') {
      return ModernUriCodec.parseHysteria2(trimmed.substring(6), subscriptionId, id);
    }
    if (scheme === 'tuic') {
      return ModernUriCodec.parseTuic(trimmed.substring(7), subscriptionId, id);
    }
    if (scheme === 'anytls') {
      return ModernUriCodec.parseAnytls(trimmed.substring(9), subscriptionId, id);
    }
    if (scheme === 'wireguard') {
      return ModernUriCodec.parseWireguard(trimmed.substring(13), subscriptionId, id);
    }
    return ModernUriCodec.parseHysteria(trimmed.substring(11), subscriptionId, id);
  }

  // 说明: 旧版曾有一个 toClashProxy() 便捷方法, 它把一切非 ss/ssr 类型都当成 ss 输出,
  // 与 ClashConfigGenerator.proxyYamlLine() 的全协议实现冲突, 且全工程无人调用,
  // 已删除以免被误用导致 vless/vmess/trojan/hysteria2 节点被降级成 ss。
}

/**
 * SSR / SS 链接编解码
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/subscription_parser_ssr_part.dart
 *                packages/ssrvpn_shared/lib/services/subscription_parser_uri_part.dart
 */
export class SsrCodec {
  private static b64 = new util.Base64Helper();
  private static decoder = util.TextDecoder.create('utf-8');

  /** URL-safe base64 → 文本（兼容缺少 padding 的情况） */
  static decodeBase64Url(input: string): string {
    let s = input.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4 !== 0) {
      s += '=';
    }
    try {
      const bytes = SsrCodec.b64.decodeSync(s, util.Type.MIME);
      return SsrCodec.decoder.decodeToString(bytes);
    } catch (e) {
      try {
        const bytes = SsrCodec.b64.decodeSync(s, util.Type.BASIC);
        return SsrCodec.decoder.decodeToString(bytes);
      } catch (e2) {
        return '';
      }
    }
  }

  static encodeBase64Url(input: string): string {
    try {
      const encoded = util.TextEncoder.create('utf-8').encodeInto(input);
      return SsrCodec.b64.encodeToStringSync(encoded, util.Type.BASIC)
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    } catch (e) {
      return '';
    }
  }

  /** 解析 ssr:// 主机:端口:协议:方法:混淆:base64密码/?obfsparam=...&protoparam=...&remarks=... */
  static parseSsr(body: string, subscriptionId: string, id: string): ProxyNode | null {
    const decoded = SsrCodec.decodeBase64Url(body);
    if (decoded.length === 0) {
      return null;
    }
    const mainSplit = decoded.split('/?');
    const mainParts = mainSplit[0].split(':');
    if (mainParts.length < 6) {
      return null;
    }
    // SSR 主体末尾五段固定为 port/protocol/method/obfs/password；
    // 从右侧取值，避免裸 IPv6 地址中的冒号把 server 拆坏。
    const tail = mainParts.length - 5;
    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.type = ProxyNodeType.SSR;
    node.rawUri = 'ssr://' + body;
    node.server = SsrCodec.stripHostBrackets(mainParts.slice(0, tail).join(':'));
    node.port = parseInt(mainParts[tail]);
    node.protocol = mainParts[tail + 1];
    node.method = mainParts[tail + 2];
    node.obfs = mainParts[tail + 3];
    node.password = mainParts[tail + 4];
    const params = mainSplit.length > 1 ? mainSplit[1] : '';
    for (const kv of params.split('&')) {
      const eq = kv.indexOf('=');
      if (eq < 0) {
        continue;
      }
      const key = kv.substring(0, eq);
      const value = SsrCodec.decodeBase64Url(kv.substring(eq + 1));
      if (key === 'remarks') {
        node.name = value;
      } else if (key === 'protoparam') {
        node.protocolParam = value;
      } else if (key === 'obfsparam') {
        node.obfsParam = value;
      }
    }
    if (node.name.length === 0) {
      node.name = node.server;
    }
    return SsrCodec.validate(node) ? node : null;
  }

  /** 解析 ss://（SIP002：base64(method:password)@host:port 或 base64 全串） */
  static parseSs(body: string, subscriptionId: string, id: string): ProxyNode | null {
    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.type = ProxyNodeType.SS;
    node.rawUri = 'ss://' + body;

    let working = body;
    const hashIdx = working.indexOf('#');
    if (hashIdx >= 0) {
      node.name = SsrCodec.percentDecode(working.substring(hashIdx + 1));
      working = working.substring(0, hashIdx);
    }
    const queryIdx = working.indexOf('?');
    let queryPart = '';
    if (queryIdx >= 0) {
      // SIP002 plugin 参数（?plugin=obfs-local;obfs=http;...）必须保留进
      // extraOpts，否则节点能导入但连不上（且无任何诊断）。outline=1 等无害
      // 参数忽略。注意先截 query 再走下面两种 userinfo 形态的解析。
      queryPart = working.substring(queryIdx + 1);
      working = working.substring(0, queryIdx);
    }
    SsrCodec.applySsPlugin(node, queryPart);

    const atIdx = working.lastIndexOf('@');
    if (atIdx >= 0) {
      const userInfo = SsrCodec.decodeBase64Url(working.substring(0, atIdx));
      const hostPart = working.substring(atIdx + 1);
      const colon = userInfo.indexOf(':');
      if (colon < 0) {
        return null;
      }
      node.method = userInfo.substring(0, colon);
      node.password = userInfo.substring(colon + 1);
      const lastColon = hostPart.lastIndexOf(':');
      if (lastColon < 0) {
        return null;
      }
      node.server = SsrCodec.stripBrackets(hostPart.substring(0, lastColon));
      node.port = parseInt(hostPart.substring(lastColon + 1));
    } else {
      const decoded = SsrCodec.decodeBase64Url(working);
      const colon = decoded.indexOf(':');
      const atIdx2 = decoded.lastIndexOf('@');
      if (colon < 0 || atIdx2 < 0) {
        return null;
      }
      node.method = decoded.substring(0, colon);
      const hostPart = decoded.substring(atIdx2 + 1);
      const lastColon = hostPart.lastIndexOf(':');
      node.password = decoded.substring(colon + 1, decoded.lastIndexOf('@'));
      node.server = SsrCodec.stripBrackets(hostPart.substring(0, lastColon));
      node.port = parseInt(hostPart.substring(lastColon + 1));
    }
    if (node.name.length === 0) {
      node.name = node.server;
    }
    return SsrCodec.validate(node) ? node : null;
  }

  private static stripBrackets(host: string): string {
    if (host.startsWith('[') && host.endsWith(']')) {
      return host.substring(1, host.length - 1);
    }
    return host;
  }

  /** 去除 IPv6 方括号（ModernUriCodec 复用） */
  static stripHostBrackets(host: string): string {
    return SsrCodec.stripBrackets(host);
  }

  /** 百分号解码（替代 decodeURIComponent 的 ArkTS 实现，覆盖中文节点名常见场景） */
  static percentDecode(input: string): string {
    let out = '';
    let i = 0;
    while (i < input.length) {
      const ch = input.charAt(i);
      if (ch === '%' && i + 2 < input.length) {
        const code = parseInt(input.substring(i + 1, i + 3), 16);
        if (!isNaN(code)) {
          out += String.fromCharCode(code);
          i += 3;
          continue;
        }
      }
      out += ch;
      i += 1;
    }
    // UTF-8 字节序列 → 字符串
    try {
      const bytes: number[] = [];
      for (let j = 0; j < out.length; j++) {
        bytes.push(out.charCodeAt(j));
      }
      return SsrCodec.decoder.decodeToString(new Uint8Array(bytes));
    } catch (e) {
      return out;
    }
  }

  static validate(node: ProxyNode): boolean {
    // NaN 端口天然被拦（NaN > 0 为 false），无需额外分支。
    return node.server.length > 0 && node.port > 0 && node.port < 65536
      && node.method.length > 0 && node.password.length > 0;
  }

  /**
   * SIP002 `?plugin=` 参数 → extraOpts 的 plugin / plugin-opts。
   * 形如 `plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com`，
   * 解码后首段是插件名，余下分号段是 plugin-opts。生成器经 extraOpts
   * 中继原样回写（见 ClashConfigGenerator extraOpts 中继段）。
   */
  private static applySsPlugin(node: ProxyNode, queryPart: string): void {
    if (queryPart.length === 0) {
      return;
    }
    const pluginRaw = ModernUriCodec.parseQuery(queryPart).get('plugin') ?? '';
    if (pluginRaw.length === 0) {
      return;
    }
    const segments = pluginRaw.split(';');
    const pluginName = segments[0].trim();
    // 插件名/参数必须是可见 ASCII：percentDecode 可解出控制字符，生成器遇到
    // 不安全值会静默跳过该键，节点缺 plugin 会连不上（且无诊断）。这里直接判无效。
    if (pluginName.length === 0 || !/^[\x20-\x7E]+$/.test(pluginName)) {
      return;
    }
    const pairs: string[][] = [['plugin', pluginName]];
    const pluginOpts = segments.slice(1).join(';').trim();
    if (pluginOpts.length > 0) {
      if (!/^[\x20-\x7E]+$/.test(pluginOpts)) {
        return;
      }
      pairs.push(['plugin-opts', pluginOpts]);
    }
    node.extraOpts = ModernUriCodec.buildExtraOpts(pairs);
  }
}

/**
 * 现代代理链接编解码（vless:// / vmess:// / trojan:// / hysteria2:// / hy2://）
 * 解析现代代理 URI，并将 Mihomo 所需字段保存到白名单结构化模型中。
 * rawYaml 仅保留为旧存储兼容占位，不参与配置生成或透传。
 */
export class ModernUriCodec {
  /** YAML 字符串值转义（双引号包裹） */
  private static q(value: string): string {
    return '"' + value.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  }

  /** 解析查询串为 Map（值做百分号解码）。ss 等协议也需要读 plugin 参数，故公开。 */
  static parseQuery(query: string): Map<string, string> {
    const out = new Map<string, string>();
    for (const kv of query.split('&')) {
      if (kv.length === 0) {
        continue;
      }
      const eq = kv.indexOf('=');
      const key = eq < 0 ? kv : kv.substring(0, eq);
      const value = eq < 0 ? '' : SsrCodec.percentDecode(kv.substring(eq + 1));
      if (key.length > 0) {
        out.set(key, value);
      }
    }
    return out;
  }

  /** 拆出 #fragment 与 ?query，返回 [剩余主体, query, 名称] */
  private static splitUri(body: string): string[] {
    let working = body;
    let name = '';
    const hashIdx = working.indexOf('#');
    if (hashIdx >= 0) {
      name = SsrCodec.percentDecode(working.substring(hashIdx + 1));
      working = working.substring(0, hashIdx);
    }
    let query = '';
    const queryIdx = working.indexOf('?');
    if (queryIdx >= 0) {
      query = working.substring(queryIdx + 1);
      working = working.substring(0, queryIdx);
    }
    return [working, query, name];
  }

  /** 主体拆 userinfo@host:port */
  private static splitHostPort(working: string): string[] {
    const atIdx = working.lastIndexOf('@');
    if (atIdx < 0) {
      return [];
    }
    const userInfo = working.substring(0, atIdx);
    const hostPart = working.substring(atIdx + 1);
    const lastColon = hostPart.lastIndexOf(':');
    if (lastColon < 0) {
      return [];
    }
    const host = SsrCodec.stripHostBrackets(hostPart.substring(0, lastColon));
    // ⚠ 端口段**原样**返回，绝不在这里 parseInt。
    // hysteria2 的端口跳跃写成 `host:1000-2000`，若此处直接 parseInt 会截断成 "1000"，
    // 跳跃区间在解析器入口就被丢掉，调用方再也拿不到原始区间。
    // 各调用方自行决定如何解释（普通协议 parseInt，hysteria2 走 splitPortHopping）。
    const rawPort = hostPart.substring(lastColon + 1).trim();
    return [userInfo, host, rawPort];
  }

  private static finish(node: ProxyNode): ProxyNode | null {
    if (node.name.length === 0) {
      node.name = node.server;
    }
    const texts: string[] = [node.name, node.server, node.password, node.method, node.protocol,
      node.protocolParam, node.obfs, node.obfsParam, node.uuid, node.network, node.servername,
      node.flow, node.clientFingerprint, node.certFingerprint, node.realityPublicKey,
      node.realityShortId, node.wsPath,
      node.wsHost, node.grpcServiceName, node.hyUp, node.hyDown, node.alpnList];
    for (const value of texts) {
      if (!ModernUriCodec.isSafeText(value)) {
        return null;
      }
    }
    if (node.name.length === 0 || node.server.length === 0 || !/^([A-Za-z0-9.-]+|[0-9A-Fa-f:]+)$/.test(node.server)
      || node.server.includes('..') || node.server.startsWith('.') || node.server.endsWith('.')
      || isNaN(node.port) || !Number.isInteger(node.port) || node.port <= 0 || node.port >= 65536
      || node.alterId < 0 || !Number.isInteger(node.alterId)) {
      return null;
    }
    if ((node.proxyType === 'vless' || node.proxyType === 'vmess')
      && !/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$/.test(node.uuid)) {
      return null;
    }
    // 支持的 network 取值必须与 mihomo 对齐：`httpupgrade` 是合法传输方式
    // （v2ray-http-upgrade，ws-opts 里配 v2ray-http-upgrade: true），
    // 此前不在白名单里 ⇒ 带 httpupgrade 的链接**整条被丢弃**。
    if (node.network.length > 0 && node.network !== 'tcp' && node.network !== 'ws'
      && node.network !== 'grpc' && node.network !== 'http' && node.network !== 'h2'
      && node.network !== 'xhttp' && node.network !== 'httpupgrade') {
      return null;
    }
    return node;
  }

  private static isSafeText(value: string): boolean {
    if (value.length > 64 * 1024 || value.includes('\n') || value.includes('\r')
      || value.includes('\u0000')) {
      return false;
    }
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code < 0x20 || code === 0x7f) {
        return false;
      }
    }
    return true;
  }

  /** vless://uuid@host:port?type=tcp&security=reality&flow=...&sni=...&pbk=...&sid=...#name */
  static parseVless(body: string, subscriptionId: string, id: string): ProxyNode | null {
    const parts = ModernUriCodec.splitUri(body);
    const working = parts[0];
    const query = ModernUriCodec.parseQuery(parts[1]);
    const name = parts[2];
    const hostInfo = ModernUriCodec.splitHostPort(working);
    if (hostInfo.length < 3) {
      return null;
    }
    const uuid = hostInfo[0];
    const host = hostInfo[1];
    const port = parseInt(hostInfo[2]);
    if (uuid.length === 0) {
      return null;
    }

    const network = query.get('type') ?? 'tcp';
    const security = query.get('security') ?? 'none';
    const flow = query.get('flow') ?? '';
    const sni = query.get('sni') ?? '';
    const fp = query.get('fp') ?? '';
    const pcs = query.get('pcs') ?? '';
    const pbk = query.get('pbk') ?? '';
    const sid = query.get('sid') ?? '';
    const wsHost = query.get('host') ?? '';
    const wsPath = query.get('path') ?? '';
    const serviceName = query.get('serviceName') ?? '';

    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = name;
    node.server = host;
    node.port = port;
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'vless';
    node.uuid = uuid;
    node.udp = true;
    node.network = network;
    node.tls = security === 'tls' || security === 'reality';
    node.flow = flow;
    node.servername = sni;
    node.clientFingerprint = fp;
    node.certFingerprint = pcs;
    if (security === 'reality') {
      node.realityPublicKey = pbk;
      node.realityShortId = sid;
    }
    if (network === 'ws' || network === 'httpupgrade') {
      node.wsPath = wsPath;
      node.wsHost = wsHost;
      // ws 早数据（mihomo common/convert/v.go 的 `ed` 参数）：
      //   ws          → max-early-data + early-data-header-name
      //   httpupgrade → v2ray-http-upgrade-fast-open: true
      // 此前 URI 路径完全没读 `ed`，链接里的早数据参数**静默丢失**；YAML 路径是好的，
      // 所以只有「从链接导入」的 ws 节点会退化成非早数据模式。
      const earlyData = query.get('ed') ?? '';
      if (earlyData.length > 0 && /^\d{1,6}$/.test(earlyData)) {
        const headerName = query.get('eh') ?? '';
        if (network === 'httpupgrade') {
          // 必须以 `ws-opts.` 前缀存：生成端只认这个前缀才会把它并回 ws-opts 结构，
          // 否则会被当成顶层键回写（`v2ray-http-upgrade-fast-open: true` 写在 proxy 顶层
          // 是无效键，且会被 mihomo 忽略）。
          node.extraOpts = ModernUriCodec.buildExtraOpts(
            [['ws-opts.v2ray-http-upgrade-fast-open', 'true']]);
        } else {
          node.extraOpts = ModernUriCodec.buildExtraOpts([
            ['ws-opts.max-early-data', earlyData],
            ['ws-opts.early-data-header-name',
              headerName.length > 0 ? headerName : 'Sec-WebSocket-Protocol']
          ]);
        }
      }
    }
    if (network === 'grpc') {
      node.grpcServiceName = serviceName;
    }
    node.rawUri = 'vless://' + body;
    node.rawYaml = '';
    return ModernUriCodec.finish(node);
  }

  /** vmess://<base64 JSON>（v2rayN 格式：ps/add/port/id/aid/scy/net/host/path/tls/sni） */
  static parseVmess(body: string, subscriptionId: string, id: string): ProxyNode | null {
    let jsonText = SsrCodec.decodeBase64Url(body.replace(/\s+/g, ''));
    if (jsonText.length === 0) {
      jsonText = body; // 极少数订阅直接给明文 JSON
    }
    let json: Record<string, Object>;
    try {
      json = JSON.parse(jsonText) as Record<string, Object>;
    } catch (e) {
      return null;
    }
    const add = (json['add'] ?? '') as string;
    if (add.length === 0) {
      return null;
    }
    const portRaw = json['port'];
    const port = typeof portRaw === 'number' ? portRaw as number : parseInt(`${portRaw}`);
    const uuid = (json['id'] ?? '') as string;
    if (uuid.length === 0 || isNaN(port) || port <= 0) {
      return null;
    }
    const ps = (json['ps'] ?? '') as string;
    const aidRaw = json['aid'];
    const aid = typeof aidRaw === 'number' ? aidRaw as number : parseInt(`${aidRaw ?? '0'}`);
    const scy = (json['scy'] ?? 'auto') as string;
    const net = (json['net'] ?? 'tcp') as string;
    const host = (json['host'] ?? '') as string;
    const path = (json['path'] ?? '') as string;
    const tls = (json['tls'] ?? '') as string;
    const sni = (json['sni'] ?? '') as string;

    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = ps;
    node.server = add;
    node.port = port;
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'vmess';
    node.uuid = uuid;
    node.alterId = isNaN(aid) ? 0 : aid;
    node.method = scy.length > 0 ? scy : 'auto';
    node.udp = true;
    node.network = net;
    node.tls = tls === 'tls';
    node.servername = sni;
    if (net === 'ws') {
      node.wsPath = path;
      node.wsHost = host;
    }
    node.rawUri = 'vmess://' + body;
    node.rawYaml = '';
    return ModernUriCodec.finish(node);
  }

  /** trojan://password@host:port?sni=xx&allowInsecure=1#name */
  static parseTrojan(body: string, subscriptionId: string, id: string): ProxyNode | null {
    const parts = ModernUriCodec.splitUri(body);
    const working = parts[0];
    const query = ModernUriCodec.parseQuery(parts[1]);
    const name = parts[2];
    const hostInfo = ModernUriCodec.splitHostPort(working);
    if (hostInfo.length < 3) {
      return null;
    }
    const password = SsrCodec.percentDecode(hostInfo[0]);
    const host = hostInfo[1];
    const port = parseInt(hostInfo[2]);
    if (password.length === 0) {
      return null;
    }
    const sni = query.get('sni') ?? '';
    const allowInsecure = query.get('allowInsecure') ?? '0';

    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = name;
    node.server = host;
    node.port = port;
    node.password = password;
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'trojan';
    node.udp = true;
    node.tls = true;
    node.servername = sni;
    node.skipCertVerify = allowInsecure === '1' || allowInsecure.toLowerCase() === 'true';
    node.rawUri = 'trojan://' + body;
    node.rawYaml = '';
    return ModernUriCodec.finish(node);
  }

  /** 带宽值规整（Hysteria2 up/down）: 仅接受 数字[单位]，如 "114"、"0.5Mbps"；非法则丢弃 */
  static normalizeHyBandwidth(value: string): string {
    const v = value.trim();
    if (v.length === 0) {
      return '';
    }
    return /^[0-9]+(\.[0-9]+)?[A-Za-z]{0,6}$/.test(v) ? v : '';
  }

  /** ALPN 规整: "h3,h4" / ["h3"] / [h3] → "h3,h4"；仅保留 alpn-h2/http/1.1/h3 等安全字符 */
  static normalizeAlpn(value: string): string {
    const cleaned = value.replace(/[\[\]"\s]/g, '');
    if (cleaned.length === 0) {
      return '';
    }
    return /^[A-Za-z0-9.,-]+$/.test(cleaned) ? cleaned : '';
  }

  /**
   * 解析 hysteria2 的端口跳跃写法（`host:1000-2000` / `host:1000,2000,3000`）。
   *
   * 为什么需要：mihomo 的 hysteria2 支持 `ports` 端口跳跃，分享链接把区间写在
   * **端口位置**（`hysteria2://pass@host:1000-2000`）。此前这里直接 `parseInt`，
   * `"1000-2000"` 被截断成 1000，跳跃区间**静默丢失** —— 节点仍能连，但只连 1000，
   * 一旦面板把 1000 封了就连不上，且完全看不出原因。
   *
   * mihomo 自己的做法（common/convert/v.go）分两步：
   *   1. 从 `host:ports` 里取出 ports 段，把端口位置替换成其中**第一个**数字，
   *      拼回一条合法 URL 再交给标准 url.Parse（见 splitHysteria2Ports）；
   *   2. `proxy["port"] = 第一个端口`，`proxy["ports"] = 原始 ports 串`。
   * 这里完全对齐：port 取首个数字，ports 原样保留区间/列表。
   *
   * @returns [首端口, ports 原文]；端口位置是单端口时返回 [该端口, '']。
   */
  static splitPortHopping(rawPortText: string): string[] {
    // hysteria2 链接常见形态是 `host:1000-2000/?insecure=1`，splitUri 只切掉 `?query`
    // 与 `#name`，所以端口段尾部会带一个路径斜杠，必须先剥掉。
    const raw = rawPortText.trim().replace(/\/+$/, '');
    if (raw.length === 0) {
      return ['', ''];
    }
    // 单端口：无 , 无 -，直接返回，ports 留空（内核不需要该键）
    if (!raw.includes(',') && !raw.includes('-')) {
      return [/^\d{1,5}$/.test(raw) ? raw : '', ''];
    }
    // 只接受 数字、逗号、连字符 的组合，避免把畸形值当成跳跃区间
    if (!/^[0-9,-]+$/.test(raw)) {
      return ['', ''];
    }
    const match = raw.match(/\d{1,5}/);
    if (match === null) {
      return ['', ''];
    }
    const first = match[0];
    const firstPort = parseInt(first);
    if (isNaN(firstPort) || firstPort <= 0 || firstPort >= 65536) {
      return ['', ''];
    }
    return [first, raw];
  }

  /** hysteria2://(hy2://)password@host:port/?insecure=1&sni=..&obfs=salamander&obfs-password=..&up=..&down=..&alpn=h3&pinSHA256=..#name */
  static parseHysteria2(body: string, subscriptionId: string, id: string): ProxyNode | null {
    const parts = ModernUriCodec.splitUri(body);
    const working = parts[0];
    const query = ModernUriCodec.parseQuery(parts[1]);
    const name = parts[2];
    const hostInfo = ModernUriCodec.splitHostPort(working);
    if (hostInfo.length < 3) {
      return null;
    }
    const password = SsrCodec.percentDecode(hostInfo[0]);
    const host = hostInfo[1];
    // 端口位置可能是跳跃区间（1000-2000）或列表（1000,2000）：取首端口做 port，
    // 原始串另存 ports（对齐 mihomo splitHysteria2Ports）
    const hopping = ModernUriCodec.splitPortHopping(hostInfo[2]);
    const port = parseInt(hopping[0]);
    const ports = hopping[1];
    if (password.length === 0) {
      return null;
    }
    const insecure = (query.get('insecure') ?? '0').toLowerCase();

    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = name;
    node.server = host;
    node.port = port;
    node.password = password;
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'hysteria2';
    node.udp = true;
    node.servername = query.get('sni') ?? '';
    node.skipCertVerify = insecure === '1' || insecure === 'true';
    node.obfs = query.get('obfs') ?? '';
    node.obfsParam = query.get('obfs-password') ?? '';
    // pinSHA256/pcs = 证书指纹 → mihomo `fingerprint`。
    // 注意 hysteria2 没有 `client-fingerprint` 键（mihomo adapter/outbound/hysteria2.go 的
    // Hysteria2Option 只有 Fingerprint，没有 ClientFingerprint），所以链接里的 `fp`
    // 对 hysteria2 无意义，刻意不落地 —— 发了也只会被内核忽略。
    node.certFingerprint = query.get('pinSHA256') ?? query.get('pcs') ?? '';
    // 带宽参数兼容 up/down 与 upmbps/downmbps 两种面板写法
    node.hyUp = ModernUriCodec.normalizeHyBandwidth(query.get('up') ?? query.get('upmbps') ?? '');
    node.hyDown = ModernUriCodec.normalizeHyBandwidth(query.get('down') ?? query.get('downmbps') ?? '');
    node.alpnList = ModernUriCodec.normalizeAlpn(query.get('alpn') ?? '');
    // 端口跳跃：区间/列表原样进 extraOpts 的 `ports`，生成配置时回写成
    // `ports: "1000-2000"`（对齐 mihomo hysteria2 的 ports 键）。port 槽位保留首端口。
    if (ports.length > 0) {
      node.extraOpts = ModernUriCodec.buildExtraOpts([['ports', ports]]);
    }
    node.rawUri = 'hysteria2://' + body;
    node.rawYaml = '';
    return ModernUriCodec.finish(node);
  }

  /** 协议专用参数 → extraOpts JSON 对（生成配置时原样回写，布尔/数字不引号）。
   * ss 的 plugin 参数也经此进入 extraOpts，故公开。 */
  static buildExtraOpts(pairs: string[][]): string {
    if (pairs.length === 0) {
      return '';
    }
    const cleaned: string[][] = [];
    for (const pair of pairs) {
      if (pair.length === 2 && pair[0].length > 0 && pair[1].length > 0) {
        cleaned.push([pair[0], pair[1]]);
      }
    }
    return cleaned.length > 0 ? JSON.stringify(cleaned) : '';
  }

  private static boolParam(query: Map<string, string>, keys: string[]): string {
    for (const k of keys) {
      const v = query.get(k);
      if (v !== undefined) {
        const normalized = v.trim().toLowerCase();
        if (normalized === '1' || normalized === 'true') {
          return 'true';
        }
        if (normalized === '0' || normalized === 'false') {
          return 'false';
        }
      }
    }
    return '';
  }

  private static numericParam(query: Map<string, string>, keys: string[]): string {
    for (const k of keys) {
      const v = query.get(k);
      if (v !== undefined && /^[0-9]+(\.[0-9]+)?$/.test(v.trim())) {
        return v.trim();
      }
    }
    return '';
  }

  private static textParam(query: Map<string, string>, keys: string[]): string {
    for (const k of keys) {
      const v = query.get(k);
      if (v !== undefined && v.trim().length > 0) {
        return v.trim();
      }
    }
    return '';
  }

  /**
   * tuic://uuid:password@host:port?sni=..&alpn=h3&congestion_control=bbr
   *   &udp_relay_mode=native&disable_sni=..&reduce_rtt=..&allow_insecure=1#name
   * 兼容 v4 token 形态 tuic://token@host:port（无冒号 → 整段视为 password）。
   */
  static parseTuic(body: string, subscriptionId: string, id: string): ProxyNode | null {
    const parts = ModernUriCodec.splitUri(body);
    const query = ModernUriCodec.parseQuery(parts[1]);
    const hostInfo = ModernUriCodec.splitHostPort(parts[0]);
    if (hostInfo.length < 3) {
      return null;
    }
    const userInfo = SsrCodec.percentDecode(hostInfo[0]);
    const colon = userInfo.indexOf(':');
    const uuid = colon >= 0 ? userInfo.substring(0, colon) : '';
    const password = colon >= 0 ? userInfo.substring(colon + 1) : userInfo;
    if (password.length === 0) {
      return null;
    }
    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = parts[2];
    node.server = hostInfo[1];
    node.port = parseInt(hostInfo[2]);
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'tuic';
    node.uuid = uuid;
    node.password = password;
    node.udp = true;
    node.tls = true;
    node.servername = ModernUriCodec.textParam(query, ['sni', 'sni_host', 'peer']);
    node.skipCertVerify = ModernUriCodec.boolParam(query, ['allow_insecure', 'allowInsecure', 'insecure']) === 'true';
    node.alpnList = ModernUriCodec.normalizeAlpn(ModernUriCodec.textParam(query, ['alpn']));
    node.extraOpts = ModernUriCodec.buildExtraOpts([
      ['congestion-controller', ModernUriCodec.textParam(query, ['congestion_control', 'congestion-controller', 'cc'])],
      ['udp-relay-mode', ModernUriCodec.textParam(query, ['udp_relay_mode', 'udp-relay-mode'])],
      ['disable-sni', ModernUriCodec.boolParam(query, ['disable_sni', 'disable-sni'])],
      ['reduce-rtt', ModernUriCodec.boolParam(query, ['reduce_rtt', 'reduce-rtt'])],
      ['udp-over-stream', ModernUriCodec.boolParam(query, ['udp_over_stream', 'udp-over-stream'])],
      ['max-udp-relay-packet-size', ModernUriCodec.numericParam(query,
        ['max_udp_relay_packet_size', 'max-udp-relay-packet-size'])]
    ]);
    node.rawUri = 'tuic://' + body;
    node.rawYaml = '';
    return ModernUriCodec.finish(node);
  }

  /** anytls://password@host:port?sni=..&insecure=1&alpn=..&fp=..#name */
  static parseAnytls(body: string, subscriptionId: string, id: string): ProxyNode | null {
    const parts = ModernUriCodec.splitUri(body);
    const query = ModernUriCodec.parseQuery(parts[1]);
    const hostInfo = ModernUriCodec.splitHostPort(parts[0]);
    if (hostInfo.length < 3) {
      return null;
    }
    const password = SsrCodec.percentDecode(hostInfo[0]);
    if (password.length === 0) {
      return null;
    }
    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = parts[2];
    node.server = hostInfo[1];
    node.port = parseInt(hostInfo[2]);
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'anytls';
    node.password = password;
    node.udp = true;
    node.tls = true;
    node.servername = ModernUriCodec.textParam(query, ['sni', 'peer']);
    node.skipCertVerify = ModernUriCodec.boolParam(query, ['insecure', 'allow_insecure', 'allowInsecure']) === 'true';
    node.alpnList = ModernUriCodec.normalizeAlpn(ModernUriCodec.textParam(query, ['alpn']));
    node.clientFingerprint = ModernUriCodec.textParam(query, ['fp', 'client-fingerprint']);
    node.certFingerprint = ModernUriCodec.textParam(query, ['pcs', 'pinSHA256', 'fingerprint']);
    node.extraOpts = ModernUriCodec.buildExtraOpts([
      ['idle-session-check-interval', ModernUriCodec.numericParam(query,
        ['idle_session_check_interval', 'idle-session-check-interval'])],
      ['idle-session-timeout', ModernUriCodec.numericParam(query,
        ['idle_session_timeout', 'idle-session-timeout'])],
      ['min-idle-session', ModernUriCodec.numericParam(query, ['min_idle_session', 'min-idle-session'])]
    ]);
    node.rawUri = 'anytls://' + body;
    node.rawYaml = '';
    return ModernUriCodec.finish(node);
  }

  /**
   * hysteria://host:port?auth=..&peer=SNI&insecure=1&upmbps=..&downmbps=..&alpn=h3&obfs=..#name
   * 也兼容 hysteria://auth@host:port?... 形态（auth 在 userinfo）。
   * Hysteria v1：口令进 password 槽（生成端同时回写 password 与 auth_str/auth-str 兜底），
   * protocol/up/down 之外的协议参数进 extraOpts。
   */
  static parseHysteria(body: string, subscriptionId: string, id: string): ProxyNode | null {
    const parts = ModernUriCodec.splitUri(body);
    const query = ModernUriCodec.parseQuery(parts[1]);
    const working = parts[0];
    const atIdx = working.lastIndexOf('@');
    let host = '';
    let portRaw = '';
    let userInfoAuth = '';
    if (atIdx >= 0) {
      userInfoAuth = working.substring(0, atIdx);
      const hostPart = working.substring(atIdx + 1);
      const lastColon = hostPart.lastIndexOf(':');
      if (lastColon < 0) {
        return null;
      }
      host = SsrCodec.stripHostBrackets(hostPart.substring(0, lastColon));
      portRaw = hostPart.substring(lastColon + 1);
    } else {
      const lastColon = working.lastIndexOf(':');
      if (lastColon < 0) {
        return null;
      }
      host = SsrCodec.stripHostBrackets(working.substring(0, lastColon));
      portRaw = working.substring(lastColon + 1);
    }
    const port = parseInt(portRaw);
    const auth = SsrCodec.percentDecode(ModernUriCodec.textParam(query, ['auth', 'auth_str', 'auth-str'])
      || userInfoAuth);
    if (auth.length === 0) {
      return null;
    }
    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = parts[2];
    node.server = host;
    node.port = port;
    node.password = auth;
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'hysteria';
    node.udp = true;
    node.servername = ModernUriCodec.textParam(query, ['peer', 'sni']);
    node.skipCertVerify = ModernUriCodec.boolParam(query, ['insecure', 'allow_insecure', 'allowInsecure']) === 'true';
    node.hyUp = ModernUriCodec.normalizeHyBandwidth(ModernUriCodec.textParam(query, ['upmbps', 'up']));
    node.hyDown = ModernUriCodec.normalizeHyBandwidth(ModernUriCodec.textParam(query, ['downmbps', 'down']));
    node.alpnList = ModernUriCodec.normalizeAlpn(ModernUriCodec.textParam(query, ['alpn']));
    // 两个指纹槽位必须分开读：`fp` 是 uTLS，`pcs` 是证书 pin（与 vless/vmess 同一套约定）
    node.clientFingerprint = ModernUriCodec.textParam(query, ['fp', 'client-fingerprint']);
    node.certFingerprint = ModernUriCodec.textParam(query, ['pcs', 'pinSHA256', 'fingerprint']);
    node.extraOpts = ModernUriCodec.buildExtraOpts([
      ['auth_str', auth],
      ['auth-str', auth],
      ['protocol', ModernUriCodec.textParam(query, ['protocol'])],
      ['obfs', ModernUriCodec.textParam(query, ['obfs'])],
      ['up', node.hyUp],
      ['down', node.hyDown],
      ['recv-window', ModernUriCodec.numericParam(query, ['recv_window', 'recv-window'])],
      ['recv-window-conn', ModernUriCodec.numericParam(query, ['recv_window_conn', 'recv-window-conn'])],
      ['disable-mtu-discovery', ModernUriCodec.boolParam(query,
        ['disable_mtu_discovery', 'disable-mtu-discovery'])]
    ]);
    node.rawUri = 'hysteria://' + body;
    node.rawYaml = '';
    return ModernUriCodec.finish(node);
  }

  /**
   * wireguard://privateKey@server:port?publicKey=..&address=..&reserved=..&mtu=..#name
   * 参数名大小写/连字符宽容（publickey/public-key、presharedkey/pre-shared-key）。
   * 映射到 mihomo wireguard 出站键，经 extraOpts 中继原样回写。
   */
  static parseWireguard(body: string, subscriptionId: string, id: string): ProxyNode | null {
    const parts = ModernUriCodec.splitUri(body);
    const query = ModernUriCodec.parseQuery(parts[1]);
    const name = parts[2];
    const hostInfo = ModernUriCodec.splitHostPort(parts[0]);
    if (hostInfo.length < 3) {
      return null;
    }
    const privateKey = SsrCodec.percentDecode(hostInfo[0]);
    // 私钥必须是 base64 形态；否则要么是残缺链接，要么含控制字符 —— 生成器
    // 遇到不安全值会静默跳过该键，节点缺 private-key 会让整份配置被内核拒绝，
    // 必须在解析侧直接判无效。
    if (privateKey.length === 0 || !/^[A-Za-z0-9+/=_-]+$/.test(privateKey)) {
      return null;
    }
    const host = hostInfo[1];
    const port = parseInt(hostInfo[2]);
    const pairs: string[][] = [['private-key', privateKey]];
    const publicKey = ModernUriCodec.textParam(query, ['public-key', 'publickey', 'publicKey']);
    if (publicKey.length > 0) {
      pairs.push(['public-key', publicKey]);
    }
    const preShared = ModernUriCodec.textParam(query, ['pre-shared-key', 'presharedkey', 'preSharedKey']);
    if (preShared.length > 0) {
      pairs.push(['pre-shared-key', preShared]);
    }
    // address: "10.0.0.2/32" 或 "10.0.0.2/32,fd00::1/128" → ip / ipv6（去 CIDR 后缀）
    const address = ModernUriCodec.textParam(query, ['address']);
    if (address.length > 0) {
      for (const item of address.split(',')) {
        const ip = item.split('/')[0].trim();
        if (ip.length === 0) {
          continue;
        }
        if (ip.includes(':')) {
          pairs.push(['ipv6', ip]);
        } else {
          pairs.push(['ip', ip]);
        }
      }
    }
    // reserved: "0,0,0" → [0,0,0]（生成器见 [ 开头原样回写）；其他形态原样透传
    const reserved = ModernUriCodec.textParam(query, ['reserved']);
    if (reserved.length > 0) {
      if (/^\d+(,\d+){0,7}$/.test(reserved)) {
        pairs.push(['reserved', `[${reserved}]`]);
      } else {
        pairs.push(['reserved', reserved]);
      }
    }
    const mtu = ModernUriCodec.numericParam(query, ['mtu']);
    if (mtu.length > 0) {
      pairs.push(['mtu', mtu]);
    }
    const udp = ModernUriCodec.boolParam(query, ['udp']);
    if (udp.length > 0) {
      pairs.push(['udp', udp]);
    }
    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = name;
    node.server = host;
    node.port = port;
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'wireguard';
    node.udp = true;
    node.extraOpts = ModernUriCodec.buildExtraOpts(pairs);
    node.rawUri = 'wireguard://' + body;
    node.rawYaml = '';
    return ModernUriCodec.finish(node);
  }
}
