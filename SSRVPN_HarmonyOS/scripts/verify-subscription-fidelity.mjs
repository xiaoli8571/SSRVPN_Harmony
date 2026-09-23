/**
 * 订阅解析保真度验证：用**真实订阅**跑**真解析器**，与 mihomo 的解析结果对账。
 *
 * 为什么必须做：解析层的既有测试（verify_yaml_compat / verify_yaml_flow_parser /
 * verify_subscription_import_regressions / protocol-regression）都是**合成 fixture**。
 * 真实面板的 YAML 有自己的形态特征（flow-map 单行条目、非标准缩进、面板推广条目、
 * 复合协议字段），合成 fixture 覆盖不到。本套件把真订阅喂给真解析器，逐节点对账。
 *
 * 做法与 verify-latency-engine-runtime.mjs 相同：把 .ets 暂存为 .ts 后 import。
 * 需要真实 YAML fixture；没有时 SKIP（不算失败）。
 *
 * 用法：node scripts/verify-subscription-fidelity.mjs <fixture.yaml>
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.join(here, '..');
const svc = path.join(appRoot, 'entry/src/main/ets/commons/services/');
const models = path.join(appRoot, 'entry/src/main/ets/commons/models/');

let passed = 0;
let failed = 0;
const failures = [];
function check(name, fn) {
  try {
    fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}
function ok(c, label) {
  if (!c) throw new Error(label);
}

function countBy(list, fn) {
  const out = {};
  for (const x of list) out[fn(x)] = (out[fn(x)] || 0) + 1;
  return out;
}
function eq(a, b, label) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}

// ── fixture ───────────────────────────────────────────────────────────────
const fixtureArg = process.argv[2] !== undefined ? process.argv[2] : '';
const defaultFixture = path.join(appRoot, 'test/fixtures/real-subscription.yaml');
const fixturePath = fixtureArg.length > 0 ? fixtureArg
  : (fs.existsSync(defaultFixture) ? defaultFixture : '');
// 无真实订阅 fixture：不算失败，但 P0 修复（混合订阅/ss plugin/SIP008/
// wireguard URI）必须有**始终执行**的真跑回归 —— 暂存照做，import 成功后
// 用真解析器跑合成核心用例（runSyntheticCore），不跑真订阅对账段。
const noFixture = fixturePath.length === 0 || !fs.existsSync(fixturePath);
if (noFixture) {
  console.log('SKIP: no real subscription fixture (pass a YAML path as argv[2])');
}
const rawYaml = noFixture ? '' : fs.readFileSync(fixturePath, 'utf8');

// ── mihomo 口径的基线：独立于被测代码，只提取结构 ─────────────────────────
function fieldOf(text, key) {
  const m = text.match(new RegExp(`(?:^|[,{\\s])${key}\\s*:\\s*('([^']*)'|"([^"]*)"|([^,\\s}]+))`));
  if (m === null) return '';
  if (m[2] !== undefined) return m[2];
  if (m[3] !== undefined) return m[3];
  return m[4];
}

/**
 * 该键在原文里是否有**真实值**（区别于 YAML null / ~ / 空）。
 * 真实订阅里 `sni: null` 是合法写法，表示"不设置"；把它当"声明了 sni"会误报。
 */
function hasRealValue(text, key) {
  const v = fieldOf(text, key);
  if (v.length === 0) return false;
  const low = v.toLowerCase();
  return low !== 'null' && low !== '~';
}

function sectionItems(yaml, section) {
  const lines = yaml.replace(/\r/g, '').split('\n');
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (new RegExp(`^${section}\\s*:\\s*$`).test(lines[i])) { start = i; break; }
  }
  if (start < 0) return [];
  const raw = [];
  let cur = null;
  let curIndent = -1;
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim().length === 0) continue;
    if (/^\S/.test(line)) break;
    const indent = line.length - line.trimStart().length;
    const isItem = /^-\s/.test(line.trimStart());
    if (isItem) {
      if (cur !== null) raw.push({ indent: curIndent, lines: cur });
      cur = [line.trim()];
      curIndent = indent;
    } else if (cur !== null) {
      cur.push(line.trim());
    }
  }
  if (cur !== null) raw.push({ indent: curIndent, lines: cur });
  if (raw.length === 0) return [];
  // 只有最浅缩进的一层才是该分节的直接子项
  const minIndent = Math.min(...raw.map(r => r.indent));
  return raw.filter(r => r.indent === minIndent).map(r => r.lines);
}

function expectedNodes(yaml) {
  const out = [];
  for (const item of sectionItems(yaml, 'proxies')) {
    const joined = item.join(' ');
    const body = joined.replace(/^-\s*/, '');
    const text = body.startsWith('{') ? body.slice(1, body.lastIndexOf('}')) : joined;
    const name = fieldOf(text, 'name');
    const type = fieldOf(text, 'type');
    if (name.length === 0 || type.length === 0) continue;
    out.push({
      name, type,
      server: fieldOf(text, 'server'),
      port: fieldOf(text, 'port'),
      hasSni: hasRealValue(text, 'sni'),
      hasSkipCertVerify: hasRealValue(text, 'skip-cert-verify')
    });
  }
  return out;
}
const expected = expectedNodes(rawYaml);
const expectedGroupCount = sectionItems(rawYaml, 'proxy-groups').length;

// ── 暂存真代码 ─────────────────────────────────────────────────────────────
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'sub-fidelity-'));
const w = (n, s) => fs.writeFileSync(path.join(stage, n), s, 'utf8');
// 相对 import 压平到暂存根（../models/X、./X → ./X.ts）
const flatten = (s) => s.replace(
  /from '(?:\.\.?\/)+(?:[A-Za-z0-9_]+\/)*([A-Za-z0-9_]+)'/g, "from './$1.ts'");
// Node strip-only 不支持 enum：把字符串 enum 降级为 class + static readonly
const stripEnums = (s) => s.replace(/export enum (\w+) \{([\s\S]*?)\n\}/g, (m, name, body) => {
  const pairs = [...body.matchAll(/(\w+)\s*=\s*'([^']*)'/g)].map(x => [x[1], x[2]]);
  return `export class ${name} {\n${pairs.map(([k, v]) => `  static readonly ${k}: string = '${v}';`).join('\n')}\n}`;
});
const stage1 = (f) => stripEnums(flatten(fs.readFileSync(f, 'utf8')));

for (const f of ['SubscriptionParser', 'YamlMerger', 'ProxyProviderParser']) {
  const p = path.join(svc, f + '.ets');
  if (fs.existsSync(p)) w(f + '.ts', stage1(p));
}
w('ProxyNode.ts', stage1(path.join(models, 'ProxyNode.ets')));
w('ProxyGroup.ts', stage1(path.join(models, 'ProxyGroup.ets')));
w('AppLogger.ts', `
export class AppLogger {
  static info() {}
  static warn() {}
  static error() {}
  static debug() {}
  static errText(e) { return String(e && e.message ? e.message : e); }
}
`);
// @kit.ArkTS 的 util.TextDecoder / TextEncoder / Base64Helper 桩
const utilStub = `
class Decoder {
  static create() { return new Decoder(); }
  decodeToString(bytes) { return Buffer.from(bytes).toString('utf8'); }
}
class Encoder {
  static create() { return new Encoder(); }
  encodeInto(s) { return new Uint8Array(Buffer.from(s, 'utf8')); }
  encodeToString(s) { return Buffer.from(s, 'utf8').toString('base64'); }
}
class Base64Helper {
  constructor() {}
  decodeSync(input) {
    let s;
    if (typeof input === 'string') s = input;
    else s = Buffer.from(input).toString('utf8');
    return new Uint8Array(Buffer.from(s, 'base64'));
  }
  decodeToStringSync(input) {
    const b = this.decodeSync(input);
    return Buffer.from(b).toString('utf8');
  }
  encodeToStringSync(input) {
    if (typeof input === 'string') return Buffer.from(input, 'utf8').toString('base64');
    return Buffer.from(input).toString('base64');
  }
}
export const util = {
  TextDecoder: Decoder,
  TextEncoder: Encoder,
  Base64Helper: Base64Helper,
  base64Helper: new Base64Helper(),
  // SsrCodec.decodeBase64Url 会读 util.Type.MIME / Type.BASIC（真实 ArkTS 常量），
  // 缺了会在 decodeSync 参数求值时抛 TypeError，被 catch 吞掉 → 解码永远返回空串。
  Type: { MIME: 0, BASIC: 1 }
};
`;
w('util.ts', utilStub);
w('@kit.ArkTS.ts', utilStub);

// 把对 '@kit.ArkTS' 的 import 改指到本地桩
for (const f of fs.readdirSync(stage)) {
  if (!f.endsWith('.ts')) continue;
  const p = path.join(stage, f);
  const s = fs.readFileSync(p, 'utf8').replace(/'@kit\.ArkTS'/g, "'./util.ts'");
  fs.writeFileSync(p, s, 'utf8');
}

let Parser = null;
let Merger = null;
let importError = '';
try {
  const mod = await import(`file://${path.join(stage, 'SubscriptionParser.ts').replace(/\\/g, '/')}`);
  Parser = mod.SubscriptionParser;
  const ymod = await import(`file://${path.join(stage, 'YamlMerger.ts').replace(/\\/g, '/')}`);
  Merger = ymod.YamlMerger;
} catch (e) {
  importError = String(e && e.message ? e.message : e);
}

console.log(`fixture: ${noFixture ? '(none)' : path.basename(fixturePath)} `
  + `(${rawYaml.length} bytes)`);
console.log(`mihomo baseline: ${expected.length} nodes, ${expectedGroupCount} groups`);
console.log(`type mix: ${JSON.stringify(countBy(expected, n => n.type))}`);
if (importError.length > 0) {
  console.log(`\nFAILED to stage/run the real parser: ${importError}`);
  console.log(`\n${passed} passed, ${failed} failed, 0 run`);
  process.exit(1);
}
if (noFixture) {
  await runSyntheticCore(Parser);
  console.log(`\n${passed} passed, ${failed} failed, ${passed + failed} run (synthetic core only)`);
  if (failures.length > 0) {
    console.log('\nfailures:');
    for (const f of failures) console.log('  - ' + f);
  }
  process.exit(failed === 0 ? 0 : 1);
}

// ── 合成核心用例（无 fixture 时也执行；P0 修复的始终真跑回归） ───────────────
// 用真解析器（stage 出的 SubscriptionParser/ProxyNode）跑：混合订阅三段共存、
// ss:// plugin 透传、SIP008 JSON、wireguard:// URI、诊断累加。
async function runSyntheticCore(Parser) {
  const mixed = 'vless://00000000-0000-4000-8000-000000000001@example.com:443?type=ws&path=%2Fws#MixNode\n'
    + 'proxies:\n'
    + '  - { name: YamlNode, server: yaml.example.com, port: 8443, type: trojan, password: pw1 }\n';
  const ssPlugin = 'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQx@example.com:8388'
    + '?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.com#PluginNode\n';
  const sip008 = '{"version":1,"servers":['
    + '{"remarks":"Sip008A","server":"a.example.com","server_port":8388,'
    + '"password":"pw-a","method":"aes-256-gcm"},'
    + '{"remarks":"Sip008B","server":"b.example.com","server_port":443,'
    + '"password":"pw-b","method":"chacha20-ietf-poly1305"}]}';
  const wireguard = 'wireguard://cHJpdmF0ZWtleTIyMjIzMzMzQGV4YW1wbGUuY29t@wg.example.com:51820'
    + '?public-key=pbl1cBase64Key111111=&address=10.0.0.2%2F32&reserved=0,0,0&mtu=1420#WgNode\n';
  const garbage = 'vless://bad-uuid@example.com:443#BadNode\n';

  // 1) 混合订阅：明文 URI 段与 YAML 段共存（旧实现三段互斥，YAML 主体丢失）
  check('混合订阅：明文 URI + YAML 主体都解析出来', () => {
    const r = Parser.parseDetailed(mixed, 'mix');
    const names = r.nodes.map(n => n.originalName);
    ok(names.includes('MixNode'), `MixNode missing: ${JSON.stringify(names)}`);
    ok(names.includes('YamlNode'), `YamlNode missing: ${JSON.stringify(names)}`);
    eq(r.nodes.length, 2, 'exactly two nodes');
  });

  // 2) ss:// plugin 透传（旧实现 query 截断后静默丢失）
  check('ss:// plugin 参数进 extraOpts（plugin + plugin-opts）', () => {
    const r = Parser.parseDetailed(ssPlugin, 'ssplug');
    eq(r.nodes.length, 1, `one node (diag=${JSON.stringify(r.diagnostics)})`);
    const n = r.nodes[0];
    // 契约：ss 走结构化槽位（type 枚举 = 'ss'），proxyType 只对现代协议填写
    eq(n.type, 'ss', 'type ss (enum)');
    const m = extraOptMap(n);
    eq(m.get('plugin'), 'obfs-local', 'plugin name');
    ok(String(m.get('plugin-opts') ?? '').includes('obfs=http'), 'plugin-opts kept');
    ok(String(m.get('plugin-opts') ?? '').includes('obfs-host=cdn.example.com'), 'obfs-host kept');
  });

  // 3) SIP008 多用户 JSON（旧实现 0 条目 EMPTY_ENTRIES）
  check('SIP008 JSON 解析为 ss 节点', () => {
    const r = Parser.parseDetailed(sip008, 'sip008');
    eq(r.nodes.length, 2, 'two servers');
    eq(r.nodes[0].name, 'Sip008A', 'remarks as name');
    eq(r.nodes[0].server, 'a.example.com', 'server');
    eq(r.nodes[0].port, 8388, 'server_port');
    eq(r.nodes[0].method, 'aes-256-gcm', 'method');
    eq(r.nodes[0].password, 'pw-a', 'password');
  });

  // 4) wireguard:// URI（旧实现整条 unsupported）
  check('wireguard:// URI 解析并透传 mihomo 键', () => {
    const r = Parser.parseDetailed(wireguard, 'wg');
    eq(r.nodes.length, 1, 'one node');
    const n = r.nodes[0];
    eq(n.proxyType, 'wireguard', 'type wireguard');
    eq(n.server, 'wg.example.com', 'server');
    eq(n.port, 51820, 'port');
    const m = extraOptMap(n);
    ok(String(m.get('private-key') ?? '').length > 0, 'private-key kept');
    ok(String(m.get('public-key') ?? '').length > 0, 'public-key kept');
    eq(m.get('reserved'), '[0,0,0]', 'reserved as array form');
    eq(m.get('mtu'), '1420', 'mtu');
    eq(m.get('ip'), '10.0.0.2', 'address -> ip (CIDR stripped)');
  });

  // 5) 诊断累加：混合订阅里无效 URI 计 invalid，不覆盖 YAML 段计数
  check('诊断累加：混合段 invalid/unsupported 不互相覆盖', () => {
    const r = Parser.parseDetailed(mixed + garbage, 'mixdiag');
    ok(r.diagnostics.invalidCount >= 1, `invalid counted: ${JSON.stringify(r.diagnostics)}`);
    ok(r.nodes.length === 2, 'still two valid nodes');
  });

  // 6) 生成器消费契约：extraOpts 经 Merger.parseExtraOpts 能解出全部键
  //    （生成器的 extraOpts 中继段就调它；生成器回写行为由 verify-config-sanitize
  //    等既有套件覆盖，此处锁"解析产出能被生成器吃进去"这一环）
  check('解析产出的 extraOpts 是生成器可消费的形状（parseExtraOpts 往返）', () => {
    const r1 = Parser.parseDetailed(ssPlugin, 'gen1');
    const pairs1 = Merger.parseExtraOpts(r1.nodes[0].extraOpts);
    const m1 = new Map(pairs1.map(p => [String(p[0]), String(p[1])]));
    ok(m1.get('plugin') === 'obfs-local', `plugin via parseExtraOpts: ${JSON.stringify(pairs1)}`);
    ok(String(m1.get('plugin-opts') ?? '').includes('obfs=http'), 'plugin-opts via parseExtraOpts');
    const r2 = Parser.parseDetailed(wireguard, 'gen2');
    const pairs2 = Merger.parseExtraOpts(r2.nodes[0].extraOpts);
    const m2 = new Map(pairs2.map(p => [String(p[0]), String(p[1])]));
    ok(String(m2.get('private-key') ?? '').length > 0, 'private-key via parseExtraOpts');
    ok(String(m2.get('public-key') ?? '').length > 0, 'public-key via parseExtraOpts');
    ok(m2.get('ip') === '10.0.0.2' && m2.get('reserved') === '[0,0,0]', 'ip/reserved via parseExtraOpts');
  });
}

// ── 真跑 ──────────────────────────────────────────────────────────────────
const res = Parser.parseDetailed(rawYaml, 'fixture');
const got = res.nodes;
console.log(`app parsed: ${got.length} nodes, ${res.groups.length} groups`);
console.log(`diagnostics: ${JSON.stringify(res.diagnostics)}`);

// ── 契约说明（本套件断言的就是这套契约） ────────────────────────────────────
// App 的节点模型有**两个**类型字段，这是刻意的设计，不是 bug：
//   - proxyType: 订阅原文里的协议名（如 'anytls'），永远保真，消费层优先用它
//   - type:      ProxyNodeType 枚举（ss/ssr/unknown），只有自研结构化解析器认识的
//                协议才填具体值，其余为 UNKNOWN
// 中继协议（tuic/hysteria/anytls/naive/shadowtls/wireguard/…）**没有结构化槽位**：
// 除 name/type/server/port 外的键**原样进 extraOpts**，由 ClashConfigGenerator 回写。
// 因此对中继协议，凭据/sni 在 extraOpts 里而不在 password/servername 槽位 —— 断言
// 必须按这套契约写，否则会把"正确的设计"误报成缺陷（本套件第一版就犯过这个错）。
function extraOptMap(node) {
  const out = new Map();
  try {
    for (const pair of JSON.parse(node.extraOpts || '[]')) out.set(pair[0], pair[1]);
  } catch (e) { /* 非法 extraOpts 当空处理 */ }
  return out;
}
function isKnownStructured(node) {
  const t = (node.proxyType || '').toLowerCase();
  return ['ss', 'ssr', 'vless', 'vmess', 'trojan', 'hysteria2'].includes(t);
}

check('every mihomo node is parsed (name+server+port)', () => {
  const keys = new Set(got.map(n => `${n.originalName || n.name}|${n.server}|${n.port}`));
  const missing = expected.filter(e => !keys.has(`${e.name}|${e.server}|${e.port}`));
  ok(missing.length === 0,
    `missing ${missing.length}/${expected.length}: ${missing.slice(0, 4).map(m => `${m.name}(${m.type})`).join(' / ')}`);
});

check('no node is invented (count <= baseline)', () => {
  ok(got.length <= expected.length, `got ${got.length} > baseline ${expected.length}`);
});

check('per-node type matches mihomo', () => {
  const byKey = new Map(got.map(n => [`${n.server}|${n.port}`, n]));
  const bad = [];
  for (const e of expected) {
    const g = byKey.get(`${e.server}|${e.port}`);
    if (g === undefined) continue;
    const gt = (g.proxyType.length > 0 ? g.proxyType : g.type).toLowerCase();
    if (gt !== e.type.toLowerCase()) bad.push(`${e.name}: mihomo=${e.type} app=${gt}`);
  }
  ok(bad.length === 0, `${bad.length} mismatched: ${bad.slice(0, 3).join(' / ')}`);
});

check('every node has server and port', () => {
  const bad = got.filter(n => n.server.length === 0 || !(n.port > 0));
  ok(bad.length === 0, `${bad.length} missing server/port: ${bad.slice(0, 3).map(n => n.name).join(' / ')}`);
});

check('credentials are reachable per contract (structured slot, or extraOpts relay)', () => {
  const bad = got.filter(n => {
    const eo = extraOptMap(n);
    if (n.uuid.length > 0 || n.password.length > 0) return false;
    if (eo.has('uuid') || eo.has('password') || eo.has('auth') || eo.has('auth-str')) return false;
    return true;
  });
  ok(bad.length === 0,
    `${bad.length} credential-less: ${bad.slice(0, 3).map(n => `${n.name}(${n.proxyType})`).join(' / ')}`);
});

check('anytls credentials reachable (real subs are anytls-heavy)', () => {
  const anytls = got.filter(n => (n.proxyType || '').toLowerCase() === 'anytls');
  ok(anytls.length > 0, 'no anytls parsed at all');
  const bad = anytls.filter(n => n.password.length === 0 && !extraOptMap(n).has('password'));
  ok(bad.length === 0, `${bad.length}/${anytls.length} anytls lost password`);
});

check('anytls sni reachable (slot or extraOpts) — only when source declares it', () => {
  // 关键：不能要求"每个 anytls 都有 sni" —— 真实订阅里有节点本来就不写 sni
  // （实测 5/21 无 sni）。断言必须**以原文为准**：原文有 sni 才要求解析后有。
  const byKey = new Map(got.map(n => [`${n.originalName || n.name}|${n.server}|${n.port}`, n]));
  const bad = [];
  for (const e of expected) {
    if (!e.hasSni) continue;
    const n = byKey.get(`${e.name}|${e.server}|${e.port}`);
    if (n === undefined) continue;
    const eo = extraOptMap(n);
    if (n.servername.length === 0 && !eo.has('sni') && !eo.has('servername')) {
      bad.push(`${e.name}(${e.type})`);
    }
  }
  ok(bad.length === 0, `${bad.length} nodes dropped a declared sni: ${bad.slice(0, 3).join(' / ')}`);
});

check('declared skip-cert-verify is reachable', () => {
  const byKey = new Map(got.map(n => [`${n.originalName || n.name}|${n.server}|${n.port}`, n]));
  const bad = [];
  for (const e of expected) {
    if (!e.hasSkipCertVerify) continue;
    const n = byKey.get(`${e.name}|${e.server}|${e.port}`);
    if (n === undefined) continue;
    if (n.skipCertVerify !== true && !extraOptMap(n).has('skip-cert-verify')) bad.push(`${e.name}(${e.type})`);
  }
  ok(bad.length === 0, `${bad.length} nodes dropped a declared skip-cert-verify: ${bad.slice(0, 3).join(' / ')}`);
});

check('skip-cert-verify reachable (slot or extraOpts)', () => {
  const anytls = got.filter(n => (n.proxyType || '').toLowerCase() === 'anytls');
  const bad = anytls.filter(n => n.skipCertVerify !== true && !extraOptMap(n).has('skip-cert-verify'));
  ok(bad.length === 0, `${bad.length}/${anytls.length} anytls dropped skip-cert-verify`);
});

check('structured protocols keep credentials in structured slots (not only extraOpts)', () => {
  const struct = got.filter(n => isKnownStructured(n));
  const bad = struct.filter(n => {
    const t = (n.proxyType || '').toLowerCase();
    if (t === 'ss' || t === 'ssr' || t === 'trojan' || t === 'hysteria2') return n.password.length === 0;
    return n.uuid.length === 0;
  });
  ok(bad.length === 0,
    `${bad.length} structured nodes missing slot credential: ${bad.slice(0, 3).map(n => `${n.name}(${n.proxyType})`).join(' / ')}`);
});

check('relay nodes do not silently pose as a known enum type', () => {
  // 中继协议应保持 type=UNKNOWN + proxyType=真实协议；若 type 被填成 'ss' 之类
  // 会让下游按错误协议生成配置。
  const relay = got.filter(n => { const t = (n.proxyType || '').toLowerCase(); return t.length > 0 && !isKnownStructured(n); });
  const lying = relay.filter(n => n.type !== 'unknown');
  ok(lying.length === 0,
    `${lying.length} relay nodes carry a concrete enum type: ${lying.slice(0, 3).map(n => `${n.name}:type=${n.type}`).join(' / ')}`);
});

check('non-node entries are not counted as nodes', () => {
  const bad = got.filter(n => ['select', 'url', 'fallback', 'relay', 'load-balance']
    .includes((n.proxyType || n.type).toLowerCase()));
  ok(bad.length === 0, `${bad.length} non-nodes: ${bad.slice(0, 3).map(n => n.name).join(' / ')}`);
});

check('names survive (originalName non-empty)', () => {
  const bad = got.filter(n => (n.originalName || '').length === 0);
  ok(bad.length === 0, `${bad.length} nodes with empty originalName`);
});

check('no duplicate counting', () => {
  const keys = got.map(n => `${n.name}|${n.server}|${n.port}`);
  const dup = [...new Set(keys.filter((k, i) => keys.indexOf(k) !== i))];
  ok(dup.length === 0, `${dup.length} duplicated: ${dup.slice(0, 3).join(' / ')}`);
});

check('proxy-groups are not lost', () => {
  ok(res.groups.length >= expectedGroupCount,
    `expected >=${expectedGroupCount}, got ${res.groups.length}`);
});

check('diagnostics are self-consistent', () => {
  if (res.diagnostics.unsupportedCount === 0) {
    ok(res.diagnostics.unsupportedTypes.length === 0,
      `unsupportedCount=0 but unsupportedTypes='${res.diagnostics.unsupportedTypes}'`);
  }
});

console.log(`\n${passed} passed, ${failed} failed, ${passed + failed} run`);
if (failures.length > 0) {
  console.log('\nfailures:');
  for (const f of failures) console.log('  - ' + f);
}
process.exit(failed === 0 ? 0 : 1);
