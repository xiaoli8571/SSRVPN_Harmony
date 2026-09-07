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
  /** 真实代理类型字符串（vless/vmess/trojan/ss/ssr…），用于展示与配置生成 */
  proxyType: string = '';
  /** 原始 Clash YAML 代理条目（多行文本，含 name）；生成内核配置时优先原样透传，
   *  以完整保留 vmess/vless/trojan 等全部字段（uuid/reality-opts/ws-opts 等） */
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
 * 现代代理链接编解码（vless:// / vmess:// / trojan://）
 * 解析 URI 并生成可直接写入 Mihomo proxies: 分节的单条 YAML（rawYaml 透传），
 * 保证 uuid / reality-opts / ws-opts / grpc-opts 等字段完整保留。
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
    if (node.server.length === 0 || isNaN(node.port) || node.port <= 0 || node.port >= 65536) {
      return null;
    }
    return node;
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

    const fields: string[] = [];
    fields.push('type: vless');
    fields.push(`server: ${host}`);
    fields.push(`port: ${port}`);
    fields.push(`uuid: ${ModernUriCodec.q(uuid)}`);
    fields.push('udp: true');
    fields.push(`network: ${network}`);
    if (security === 'tls' || security === 'reality') {
      fields.push('tls: true');
    }
    if (flow.length > 0) {
      fields.push(`flow: ${ModernUriCodec.q(flow)}`);
    }
    if (sni.length > 0) {
      fields.push(`servername: ${ModernUriCodec.q(sni)}`);
    }
    if (fp.length > 0) {
      fields.push(`client-fingerprint: ${ModernUriCodec.q(fp)}`);
    }
    if (security === 'reality' && pbk.length > 0) {
      const realityParts: string[] = [];
      realityParts.push(`public-key: ${ModernUriCodec.q(pbk)}`);
      if (sid.length > 0) {
        realityParts.push(`short-id: ${ModernUriCodec.q(sid)}`);
      }
      fields.push(`reality-opts: {${realityParts.join(', ')}}`);
    }
    if (network === 'ws') {
      const wsParts: string[] = [];
      if (wsPath.length > 0) {
        wsParts.push(`path: ${ModernUriCodec.q(wsPath)}`);
      }
      if (wsHost.length > 0) {
        wsParts.push(`headers: {Host: ${ModernUriCodec.q(wsHost)}}`);
      }
      if (wsParts.length > 0) {
        fields.push(`ws-opts: {${wsParts.join(', ')}}`);
      }
    }
    if (network === 'grpc' && serviceName.length > 0) {
      fields.push(`grpc-opts: {grpc-service-name: ${ModernUriCodec.q(serviceName)}}`);
    }

    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = name;
    node.server = host;
    node.port = port;
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'vless';
    node.rawUri = 'vless://' + body;
    node.rawYaml = `- {name: ${ModernUriCodec.q(name.length > 0 ? name : host)}, ${fields.join(', ')}}`;
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

    const fields: string[] = [];
    fields.push('type: vmess');
    fields.push(`server: ${add}`);
    fields.push(`port: ${port}`);
    fields.push(`uuid: ${ModernUriCodec.q(uuid)}`);
    fields.push(`alterId: ${isNaN(aid) ? 0 : aid}`);
    fields.push(`cipher: ${ModernUriCodec.q(scy.length > 0 ? scy : 'auto')}`);
    fields.push('udp: true');
    fields.push(`network: ${net}`);
    if (tls === 'tls') {
      fields.push('tls: true');
    }
    if (sni.length > 0) {
      fields.push(`servername: ${ModernUriCodec.q(sni)}`);
    }
    if (net === 'ws') {
      const wsParts: string[] = [];
      if (path.length > 0) {
        wsParts.push(`path: ${ModernUriCodec.q(path)}`);
      }
      if (host.length > 0) {
        wsParts.push(`headers: {Host: ${ModernUriCodec.q(host)}}`);
      }
      if (wsParts.length > 0) {
        fields.push(`ws-opts: {${wsParts.join(', ')}}`);
      }
    }

    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = ps;
    node.server = add;
    node.port = port;
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'vmess';
    node.rawUri = 'vmess://' + body;
    node.rawYaml = `- {name: ${ModernUriCodec.q(ps.length > 0 ? ps : add)}, ${fields.join(', ')}}`;
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

    const fields: string[] = [];
    fields.push('type: trojan');
    fields.push(`server: ${host}`);
    fields.push(`port: ${port}`);
    fields.push(`password: ${ModernUriCodec.q(password)}`);
    fields.push('udp: true');
    if (sni.length > 0) {
      fields.push(`sni: ${ModernUriCodec.q(sni)}`);
    }
    if (allowInsecure === '1' || allowInsecure.toLowerCase() === 'true') {
      fields.push('skip-cert-verify: true');
    }

    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = name;
    node.server = host;
    node.port = port;
    node.password = password;
    node.type = ProxyNodeType.UNKNOWN;
    node.proxyType = 'trojan';
    node.rawUri = 'trojan://' + body;
    node.rawYaml = `- {name: ${ModernUriCodec.q(name.length > 0 ? name : host)}, ${fields.join(', ')}}`;
    return ModernUriCodec.finish(node);
  }
}
