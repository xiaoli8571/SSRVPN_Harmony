/**
 * 订阅 YAML 合并引擎
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/subscription_yaml_merger.dart
 *                packages/ssrvpn_shared/lib/utils/bounded_yaml.dart
 *
 * 语义对齐：proxies 分节提取与缩进规整、条目切分、按内容指纹跨订阅去重（保留归属）、
 *           与 previousYaml 的同名节点保留（刷新不重排名称）、唯一名 "(n)" 后缀、全部限额。
 * 简化说明：upstream 用完整 YAML 解析器 + dialer-proxy 依赖解析；本移植针对 ss/ssr 节点
 *           的标量字段（flow-map 与块列表两种写法）做解析，dialer-proxy 依赖不在 ss/ssr
 *           订阅中出现，暂不实现（已记 PORTING_STATUS）。
 */
import { util } from '@kit.ArkTS';

/** 单个合并后的代理节点（ss/ssr 标量字段 + 原始 YAML 条目透传） */
export class MergedProxy {
  name: string = '';
  type: string = 'ss';
  server: string = '';
  port: number = 0;
  cipher: string = '';
  password: string = '';
  protocol: string = '';
  protocolParam: string = '';
  obfs: string = '';
  obfsParam: string = '';
  /** 原始 proxies 条目（含缩进的多行文本）；vmess/vless/trojan 等类型依赖它生成正确配置 */
  rawYaml: string = '';
}

/** 合并限额（照抄 upstream SubscriptionYamlMerger 常量） */
export class MergeLimits {
  static readonly MAX_MERGED_PROXY_NODES: number = 10000;
  static readonly MAX_MERGE_SOURCES: number = 1000;
  static readonly MAX_PROXY_FIELD_LENGTH: number = 64 * 1024;
  static readonly MAX_PROXY_ITEM_BYTES: number = 128 * 1024;
  static readonly MAX_MERGED_OUTPUT_BYTES: number = 20 * 1024 * 1024;
}

export class YamlMergeError extends Error {
  constructor(message: string) {
    super(message);
  }
}

export class YamlMerger {
  /** 提取指定顶层分节并归一化缩进为 2 空格（对齐 _normalizedSectionLines） */
  static extractSection(yaml: string, sectionName: string): string {
    const lines = YamlMerger.normalizedSectionLines(yaml, sectionName);
    return lines.join('\n');
  }

  private static sectionLines(yaml: string, sectionName: string): string[] {
    const out: string[] = [];
    let inSection = false;
    const rawLines = yaml.split('\n');
    for (const line of rawLines) {
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        const trimmed = line.trim();
        if (trimmed.startsWith(`${sectionName}:`)) {
          inSection = true;
          continue;
        }
        if (inSection && trimmed.includes(':') && !trimmed.startsWith('#') && !trimmed.startsWith('-')) {
          break;
        }
      }
      if (inSection) {
        out.push(line);
      }
    }
    return out;
  }

  private static normalizedSectionLines(yaml: string, sectionName: string): string[] {
    const section = YamlMerger.sectionLines(yaml, sectionName);
    let minIndent = 999;
    for (const line of section) {
      const trimmed = line.trimStart();
      if (trimmed.length === 0) {
        continue;
      }
      const indent = line.length - trimmed.length;
      if (indent < minIndent) {
        minIndent = indent;
      }
    }
    if (minIndent === 999) {
      minIndent = 0;
    }
    const out: string[] = [];
    for (const line of section) {
      const trimmed = line.trimStart();
      if (trimmed.length === 0) {
        continue;
      }
      const delta = line.length - trimmed.length - minIndent;
      let pad = '';
      for (let i = 0; i < delta + 2; i++) {
        pad += ' ';
      }
      out.push(`${pad}${trimmed}`);
    }
    return out;
  }

  /** proxies 条目切分（对齐 _proxyItemsFromLines：以 "  - " 起始，续行归并） */
  static proxyItemGroups(yaml: string): string[][] {
    const lines = YamlMerger.normalizedSectionLines(yaml, 'proxies');
    const items: string[][] = [];
    let current: string[] | null = null;
    for (const line of lines) {
      if (line.startsWith('  - ')) {
        if (current !== null) {
          items.push(current);
        }
        current = [line];
      } else if (current !== null) {
        current.push(line);
      }
    }
    if (current !== null) {
      items.push(current);
    }
    return items;
  }

  /**
   * 解析单个 proxies 条目（替代 upstream BoundedYaml.load 的流式解析）：
   * 支持 flow-map（`- {k: v, ...}`）与块列表（`- k: v` 续行）两种写法。
   */
  static parseProxyItem(itemLines: string[]): MergedProxy | null {
    const text = itemLines.join('\n').trim();
    if (text.length > MergeLimits.MAX_PROXY_ITEM_BYTES) {
      throw new YamlMergeError('单个节点内容大小超过上限');
    }
    const fields = new Map<string, string>();
    const body = text.startsWith('- ') ? text.substring(2) : text;
    if (body.trimStart().startsWith('{')) {
      // flow-map：按逗号切顶层（值内不含裸 { }，覆盖 ss/ssr 常见字段）
      const inner = body.trim();
      const content = inner.substring(inner.indexOf('{') + 1, inner.lastIndexOf('}'));
      for (const pair of content.split(',')) {
        const idx = pair.indexOf(':');
        if (idx < 0) {
          continue;
        }
        const key = pair.substring(0, idx).trim().replace(/^['"]|['"]$/g, '');
        const value = pair.substring(idx + 1).trim().replace(/^['"]|['"]$/g, '');
        if (key.length > 0) {
          fields.set(key, value);
        }
      }
    } else {
      // 块写法：- key: value
      for (const line of itemLines) {
        const t = line.trim().replace(/^- /, '');
        const idx = t.indexOf(':');
        if (idx < 0) {
          continue;
        }
        const key = t.substring(0, idx).trim();
        const value = t.substring(idx + 1).trim().replace(/^['"]|['"]$/g, '');
        if (key.length > 0) {
          fields.set(key, value);
        }
      }
    }
    const name = fields.get('name') ?? '';
    const server = fields.get('server') ?? '';
    const portStr = fields.get('port') ?? '0';
    if (name.length === 0 || server.length === 0) {
      return null;
    }
    const p = new MergedProxy();
    p.name = name;
    p.type = fields.get('type') ?? 'ss';
    p.server = server;
    const portNum = parseInt(portStr);
    p.port = isNaN(portNum) ? 0 : portNum;
    p.cipher = fields.get('cipher') ?? '';
    p.password = fields.get('password') ?? '';
    p.protocol = fields.get('protocol') ?? '';
    p.protocolParam = fields.get('protocol-param') ?? fields.get('protocol_param') ?? '';
    p.obfs = fields.get('obfs') ?? '';
    p.obfsParam = fields.get('obfs-param') ?? fields.get('obfs_param') ?? '';
    // 保留原始条目（含 flow-map 与块写法），供配置生成阶段完整透传全部字段
    p.rawYaml = itemLines.join('\n');
    return p;
  }

  /** 内容指纹：除 name 外全部字段按 key 排序后 JSON（对齐 _proxyIdentityContent） */
  static identityFingerprint(p: MergedProxy): string {
    const obj: Record<string, string | number> = {};
    obj['type'] = p.type;
    obj['server'] = p.server;
    obj['port'] = p.port;
    obj['cipher'] = p.cipher;
    obj['password'] = p.password;
    obj['protocol'] = p.protocol;
    obj['protocolParam'] = p.protocolParam;
    obj['obfs'] = p.obfs;
    obj['obfsParam'] = p.obfsParam;
    const keys = Object.keys(obj).sort();
    const parts: string[] = [];
    for (const k of keys) {
      parts.push(`"${k}":${JSON.stringify(obj[k])}`);
    }
    return `{${parts.join(',')}}`;
  }

  /** 唯一名（对齐 uniqueProxyName：首个复用原名，之后 " (2)"、" (3)" 递增） */
  static uniqueProxyName(baseName: string, used: Set<string>, nextByBase: Map<string, number>): string {
    const tracked = nextByBase.get(baseName);
    if (tracked === undefined && !used.has(baseName)) {
      used.add(baseName);
      nextByBase.set(baseName, 2);
      return baseName;
    }
    let suffix = tracked !== undefined ? tracked : 2;
    let candidate = `${baseName} (${suffix})`;
    while (used.has(candidate)) {
      suffix = suffix + 1;
      candidate = `${baseName} (${suffix})`;
    }
    used.add(candidate);
    nextByBase.set(baseName, suffix + 1);
    return candidate;
  }

  /**
   * 合并多个订阅 YAML（对齐 mergeYamlConfigs 主流程）：
   * 跨订阅按内容指纹去重 → previousYaml 同内容节点保留名称 → 其余唯一名分配。
   */
  static merge(yamls: string[], sourceName: string, previousYaml: string): MergedProxy[] {
    if (yamls.length > MergeLimits.MAX_MERGE_SOURCES) {
      throw new YamlMergeError('订阅来源数量超过上限 (1000)');
    }
    if (sourceName.length > MergeLimits.MAX_PROXY_FIELD_LENGTH) {
      throw new YamlMergeError('订阅字段长度超过上限 (64KB)');
    }

    // 1) 收集全部新节点（限额：总数 / 单条大小 / 字段长度）
    const fresh: MergedProxy[] = [];
    let count = 0;
    for (const yaml of yamls) {
      for (const itemLines of YamlMerger.proxyItemGroups(yaml)) {
        count = count + 1;
        if (count > MergeLimits.MAX_MERGED_PROXY_NODES) {
          throw new YamlMergeError('订阅节点数量超过上限 (10000)');
        }
        const p = YamlMerger.parseProxyItem(itemLines);
        if (p === null) {
          continue;
        }
        if (p.name.length > MergeLimits.MAX_PROXY_FIELD_LENGTH
          || p.server.length > MergeLimits.MAX_PROXY_FIELD_LENGTH
          || p.password.length > MergeLimits.MAX_PROXY_FIELD_LENGTH) {
          throw new YamlMergeError('订阅字段长度超过上限 (64KB)');
        }
        fresh.push(p);
      }
    }

    // 2) 上一轮缓存中的名称保留表：内容指纹 → 名称
    const previousNameByFingerprint = new Map<string, string>();
    if (previousYaml.length > 0) {
      let prevCount = 0;
      for (const itemLines of YamlMerger.proxyItemGroups(previousYaml)) {
        prevCount = prevCount + 1;
        if (prevCount > MergeLimits.MAX_MERGED_PROXY_NODES) {
          throw new YamlMergeError('历史缓存节点数量超过上限');
        }
        const old = YamlMerger.parseProxyItem(itemLines);
        if (old === null) {
          continue;
        }
        const fp = YamlMerger.identityFingerprint(old);
        if (!previousNameByFingerprint.has(fp)) {
          previousNameByFingerprint.set(fp, old.name);
        }
      }
    }

    // 3) 跨订阅指纹去重 + 名称分配（旧名优先，其余唯一名）
    const used = new Set<string>();
    const seenFingerprints = new Set<string>();
    const nextByBase = new Map<string, number>();
    const merged: MergedProxy[] = [];
    let outputBytes = 9; // "proxies:\n"
    for (const p of fresh) {
      const fp = YamlMerger.identityFingerprint(p);
      if (seenFingerprints.has(fp)) {
        continue;
      }
      seenFingerprints.add(fp);
      const preserved = previousNameByFingerprint.get(fp);
      if (preserved !== undefined && !used.has(preserved)) {
        p.name = preserved;
        used.add(preserved);
      } else {
        p.name = YamlMerger.uniqueProxyName(p.name, used, nextByBase);
      }
      // 输出体积限额
      outputBytes = outputBytes + 5 + util.TextEncoder.create('utf-8').encodeInto(p.name).length
        + p.server.length + p.password.length + 80;
      if (outputBytes > MergeLimits.MAX_MERGED_OUTPUT_BYTES) {
        throw new YamlMergeError('合并结果大小超过上限 (20MB)');
      }
      merged.push(p);
    }
    return merged;
  }
}
