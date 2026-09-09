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
  clientFingerprint: string = '';
  realityPublicKey: string = '';
  realityShortId: string = '';
  wsPath: string = '';
  wsHost: string = '';
  grpcServiceName: string = '';
  /** Hysteria2 (QUIC) 专属：带宽 up/down (Mbps)、口令混淆、ALPN。
   *  复用字段: password=认证口令, servername=sni, skipCertVerify=insecure,
   *  obfs=salamander/gecko, obfsParam=obfs-password, clientFingerprint=pinSHA256。 */
  hyUp: string = '';
  hyDown: string = '';
  alpnList: string = '';
  rawYaml: string = '';
  rawUri: string = '';
  groupName: string = '';

  static fromUri(uri: string, subscriptionId: string, id: string): ProxyNode | null {
    const trimmed = uri.trim();
    if (trimmed.startsWith('ssr://')) {
      return SsrCodec.parseSsr(trimmed.substring(6), subscriptionId, id);
    }
    if (trimmed.startsWith('ss://')) {
      return SsrCodec.parseSs(trimmed.substring(5), subscriptionId, id);
    }
    if (trimmed.startsWith('vless://')) {
      return ModernUriCodec.parseVless(trimmed.substring(8), subscriptionId, id);
    }
    if (trimmed.startsWith('vmess://')) {
      return ModernUriCodec.parseVmess(trimmed.substring(8), subscriptionId, id);
    }
    if (trimmed.startsWith('trojan://')) {
      return ModernUriCodec.parseTrojan(trimmed.substring(9), subscriptionId, id);
    }
    if (trimmed.startsWith('hysteria2://')) {
      return ModernUriCodec.parseHysteria2(trimmed.substring(12), subscriptionId, id);
    }
    if (trimmed.startsWith('hy2://')) {
      return ModernUriCodec.parseHysteria2(trimmed.substring(6), subscriptionId, id);
    }
    return null;
  }

  toClashProxy(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['name'] = this.name;
    out['server'] = this.server;
    out['port'] = this.port;
    out['cipher'] = this.method;
    out['password'] = this.password;
    if (this.type === ProxyNodeType.SSR) {
      out['type'] = 'ssr';
      out['protocol'] = this.protocol;
      out['protocol-param'] = this.protocolParam;
      out['obfs'] = this.obfs;
      out['obfs-param'] = this.obfsParam;
    } else {
      out['type'] = 'ss';
    }
    return out;
  }
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
    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.type = ProxyNodeType.SSR;
    node.rawUri = 'ssr://' + body;
    node.server = mainParts[0];
    node.port = parseInt(mainParts[1]);
    node.protocol = mainParts[2];
    node.method = mainParts[3];
    node.obfs = mainParts[4];
    node.password = mainParts[5];
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
    if (queryIdx >= 0) {
      working = working.substring(0, queryIdx);
    }

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
    return node.server.length > 0 && node.port > 0 && node.port < 65536
      && node.method.length > 0 && node.password.length > 0;
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

  /** 解析查询串为 Map（值做百分号解码） */
  private static parseQuery(query: string): Map<string, string> {
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
    const port = parseInt(hostPart.substring(lastColon + 1));
    return [userInfo, host, `${port}`];
  }

  private static finish(node: ProxyNode): ProxyNode | null {
    if (node.name.length === 0) {
      node.name = node.server;
    }
    const texts: string[] = [node.name, node.server, node.password, node.method, node.protocol,
      node.protocolParam, node.obfs, node.obfsParam, node.uuid, node.network, node.servername,
      node.flow, node.clientFingerprint, node.realityPublicKey, node.realityShortId, node.wsPath,
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
    if (node.network.length > 0 && node.network !== 'tcp' && node.network !== 'ws'
      && node.network !== 'grpc' && node.network !== 'http' && node.network !== 'h2') {
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
    if (security === 'reality') {
      node.realityPublicKey = pbk;
      node.realityShortId = sid;
    }
    if (network === 'ws') {
      node.wsPath = wsPath;
      node.wsHost = wsHost;
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
    const port = parseInt(hostInfo[2]);
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
    node.clientFingerprint = query.get('pinSHA256') ?? '';
    // 带宽参数兼容 up/down 与 upmbps/downmbps 两种面板写法
    node.hyUp = ModernUriCodec.normalizeHyBandwidth(query.get('up') ?? query.get('upmbps') ?? '');
    node.hyDown = ModernUriCodec.normalizeHyBandwidth(query.get('down') ?? query.get('downmbps') ?? '');
    node.alpnList = ModernUriCodec.normalizeAlpn(query.get('alpn') ?? '');
    node.rawUri = 'hysteria2://' + body;
    node.rawYaml = '';
    return ModernUriCodec.finish(node);
  }
}
