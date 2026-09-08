import { describe, it, expect } from '@ohos/hypium';
import { SubscriptionParser } from '../../../../../main/ets/commons/services/SubscriptionParser';
import { ClashConfigGenerator } from '../../../../../main/ets/commons/services/ClashConfigGenerator';
import { NodeCountryPolicy } from '../../../../../main/ets/commons/services/PublicIpService';
import { SubscriptionFetchPolicy } from '../../../../../main/ets/commons/services/SubscriptionFetchPolicy';
import { LogRedactor } from '../../../../../main/ets/commons/utils/AppLogger';
import { YamlMerger } from '../../../../../main/ets/commons/services/YamlMerger';
import { LatencyStyle, NodeDisplay } from '../../../../../main/ets/theme/UiTokens';
import { AppSettings } from '../../../../../main/ets/commons/models/AppSettings';
import { ProxyNode } from '../../../../../main/ets/commons/models/ProxyNode';

export default function logicTest() {
  describe('ssrvpnLogicTest', () => {
    it('ssr_parse', 0, () => {
      // ssr:// 1.2.3.4:8388:origin:aes-256-cfb:plain:<base64("pass")>/?remarks=<base64("测试")>
      const pass = 'cGFzcw==';
      const remarks = '5rGf6IO9';
      const uri = `ssr://1.2.3.4:8388:origin:aes-256-cfb:plain:${pass}/?remarks=${remarks}&obfsparam=`;
      const nodes = SubscriptionParser.parse(uri, 'sub1');
      expect(nodes.length).assertEqual(1);
      expect(nodes[0].server).assertEqual('1.2.3.4');
      expect(nodes[0].port).assertEqual(8388);
      expect(nodes[0].method).assertEqual('aes-256-cfb');
      expect(nodes[0].password).assertEqual('pass');
      expect(nodes[0].name).assertEqual('测试');
    });

    it('ss_parse_sip002', 0, () => {
      // ss:// base64("aes-256-gcm:secret")@example.com:443#节点名
      const userInfo = 'YWVzLTI1Ni1nY206c2VjcmV0';
      const uri = `ss://${userInfo}@example.com:443#%E6%97%A5%E6%9C%AC01`;
      const nodes = SubscriptionParser.parse(uri, 'sub1');
      expect(nodes.length).assertEqual(1);
      expect(nodes[0].server).assertEqual('example.com');
      expect(nodes[0].port).assertEqual(443);
      expect(nodes[0].method).assertEqual('aes-256-gcm');
      expect(nodes[0].password).assertEqual('secret');
      expect(nodes[0].name).assertEqual('日本01');
    });

    it('base64_subscription', 0, () => {
      const line = 'ssr://MS4yLjMuNDo4Mzg4Om9yaWdpbjphZXMtMjU2LWNmYjpwbGFpbjpjR0Z6YzNJPz9yZW1hcmtzPQ==';
      const nodes = SubscriptionParser.parse(line, 'sub1');
      expect(nodes.length >= 1).assertTrue();
    });

    it('clash_yaml_parse', 0, () => {
      const yaml = 'port: 7890\nproxies:\n' +
        "  - {name: 'HK-01', type: ss, server: h.example.com, port: 443, cipher: aes-128-gcm, password: 'pw1'}\n" +
        "  - {name: 'US-01', type: ssr, server: u.example.com, port: 8388, cipher: aes-256-cfb, password: 'pw2', protocol: origin, obfs: plain}\n";
      const nodes = SubscriptionParser.parse(yaml, 'sub2');
      expect(nodes.length).assertEqual(2);
      expect(nodes[0].name).assertEqual('HK-01');
      expect(nodes[1].type === 'ssr').assertTrue();
    });

    it('config_generator_ipv4_only_and_mode', 0, () => {
      const s = new AppSettings();
      const node = new ProxyNode();
      node.name = 'HK-01';
      node.server = 'h.example.com';
      node.port = 443;
      node.method = 'aes-128-gcm';
      node.password = 'pw';
      const yaml = ClashConfigGenerator.generate(node, [node], s, 7890, 9090, 'sec');
      expect(yaml.includes('ipv6: false')).assertTrue();
      expect(yaml.includes('mode: rule')).assertTrue();
      expect(yaml.includes('external-controller: 127.0.0.1:9090')).assertTrue();
      expect(yaml.includes('GEOIP,CN,DIRECT')).assertTrue();
      const sGlobal = new AppSettings();
      sGlobal.proxyMode = 'global';
      const yamlGlobal = ClashConfigGenerator.generate(node, [node], sGlobal, 7890, 9090, 'sec');
      expect(yamlGlobal.includes('mode: global')).assertTrue();
      expect(yamlGlobal.includes('MATCH,PROXY')).assertTrue();
    });

    it('config_generator_force_sites', 0, () => {
      const s = new AppSettings();
      s.forceProxySites = ['openai.com'];
      const node = new ProxyNode();
      node.name = 'n';
      node.server = 's';
      node.port = 1;
      node.method = 'aes-128-gcm';
      node.password = 'p';
      const yaml = ClashConfigGenerator.generate(node, [node], s, 7890, 9090, 'sec');
      expect(yaml.includes('DOMAIN-SUFFIX,openai.com,PROXY')).assertTrue();
    });

    it('country_detect', 0, () => {
      expect(NodeCountryPolicy.detect('🇭🇰 香港 IEPL 01').code).assertEqual('HK');
      expect(NodeCountryPolicy.detect('Japan Tokyo 02').code).assertEqual('JP');
      expect(NodeCountryPolicy.detect('unknown-node').code).assertEqual('XX');
    });

    it('log_redact', 0, () => {
      const red = LogRedactor.redact('connect password=abc123 to https://sub.example.com/token123');
      expect(red.includes('abc123')).assertFalse();
      expect(red.includes('password=***')).assertTrue();
    });

    it('node_display', 0, () => {
      expect(NodeDisplay.withoutLeadingFlag('🇭🇰 香港 01')).assertEqual('香港 01');
      const long = 'a'.repeat(40);
      expect(NodeDisplay.compact(long).length).assertLarger(0);
      expect(NodeDisplay.compact(long).length).assertSmallerOrEqual(24);
    });

    it('latency_style', 0, () => {
      expect(LatencyStyle.color(null)).assertEqual('#A7AFC2');
      expect(LatencyStyle.color(120)).assertEqual('#29C978');
      expect(LatencyStyle.color(200)).assertEqual('#F3B83F');
      expect(LatencyStyle.color(400)).assertEqual('#E35D6A');
      expect(LatencyStyle.text(-1)).assertEqual('超时');
      expect(LatencyStyle.text(null)).assertEqual('--');
    });

    it('yaml_merger_dedupe_and_name_preserve', 0, () => {
      const yaml1 = 'proxies:\n' +
        "  - {name: 'A', type: ss, server: a.com, port: 1, cipher: aes-128-gcm, password: p}\n" +
        "  - {name: 'B', type: ss, server: b.com, port: 2, cipher: aes-128-gcm, password: p}\n";
      const yaml2 = 'proxies:\n' +
        "  - {name: 'A-2', type: ss, server: a.com, port: 1, cipher: aes-128-gcm, password: p}\n" +
        "  - {name: 'C', type: ss, server: c.com, port: 3, cipher: aes-128-gcm, password: p}\n";
      // 第一次合并
      const first = YamlMerger.merge([yaml1], 'subA', '');
      expect(first.length).assertEqual(2);
      // 第二次刷新（A 内容不变 → 名称保留；C 为新节点）
      const second = YamlMerger.merge([yaml2], 'subA', YamlMerger.toYaml(first));
      expect(second.length).assertEqual(2);
      let hasA = false;
      let hasC = false;
      for (const m of second) {
        if (m.server === 'a.com') {
          hasA = true;
          expect(m.name).assertEqual('A');
        }
        if (m.server === 'c.com') {
          hasC = true;
        }
      }
      expect(hasA).assertTrue();
      expect(hasC).assertTrue();
    });

    it('mixed_protocol_yaml_skips_bad_nodes_and_roundtrips_options', 0, () => {
      const yaml = 'proxies:\n' +
        '  - {name: "SS", type: ss, server: ss.example.com, port: 443, cipher: aes-128-gcm, password: "pw"}\n' +
        '  - {name: "bad", type: ss, server: bad.example.com, port: 70000, cipher: aes-128-gcm, password: "pw"}\n' +
        '  - {name: "VL", type: vless, server: vl.example.com, port: 443, uuid: "123e4567-e89b-12d3-a456-426614174000", network: ws, tls: true, reality-opts: {public-key: "pk", short-id: "sid"}, ws-opts: {path: "/ws", headers: {Host: "cdn.example.com"}}}\n' +
        '  - {name: "VM", type: vmess, server: vm.example.com, port: 443, uuid: "123e4567-e89b-12d3-a456-426614174001", alterId: 0, cipher: auto, network: grpc, tls: true, grpc-opts: {grpc-service-name: "svc"}}\n' +
        '  - {name: "TR", type: trojan, server: tr.example.com, port: 443, password: "secret", tls: true}\n';
      const parsed = SubscriptionParser.parse(yaml, 'mixed');
      expect(parsed.length).assertEqual(4);
      const merged = YamlMerger.merge([yaml], 'mixed', '');
      expect(merged.length).assertEqual(4);
      const cached = YamlMerger.toYaml(merged);
      const reread = SubscriptionParser.parse(cached, 'reread');
      expect(reread.length).assertEqual(4);
      const vl = reread.find((n) => n.proxyType === 'vless');
      const vm = reread.find((n) => n.proxyType === 'vmess');
      expect(vl !== undefined).assertTrue();
      expect(vm !== undefined).assertTrue();
      expect(vl?.realityPublicKey ?? '').assertEqual('pk');
      expect(vl?.realityShortId ?? '').assertEqual('sid');
      expect(vl?.wsPath ?? '').assertEqual('/ws');
      expect(vl?.wsHost ?? '').assertEqual('cdn.example.com');
      expect(vm?.grpcServiceName ?? '').assertEqual('svc');
    });

    it('config_generator_all_protocols_and_injection_defense', 0, () => {
      const ss = new ProxyNode();
      ss.id = 'ss'; ss.name = 'SS'; ss.server = 'ss.example.com'; ss.port = 443;
      ss.method = 'aes-128-gcm'; ss.password = 'pw'; ss.proxyType = 'ss';
      const vless = new ProxyNode();
      vless.id = 'vl'; vless.name = 'VLESS'; vless.server = 'vl.example.com'; vless.port = 443;
      vless.proxyType = 'vless'; vless.uuid = '123e4567-e89b-12d3-a456-426614174000';
      vless.network = 'ws'; vless.tls = true; vless.wsPath = '/ws'; vless.wsHost = 'cdn.example.com';
      const vmess = new ProxyNode();
      vmess.id = 'vm'; vmess.name = 'VMESS'; vmess.server = 'vm.example.com'; vmess.port = 443;
      vmess.proxyType = 'vmess'; vmess.uuid = '123e4567-e89b-12d3-a456-426614174001';
      vmess.method = 'auto'; vmess.network = 'grpc'; vmess.grpcServiceName = 'svc';
      const trojan = new ProxyNode();
      trojan.id = 'tr'; trojan.name = 'TROJAN'; trojan.server = 'tr.example.com'; trojan.port = 443;
      trojan.proxyType = 'trojan'; trojan.password = 'secret'; trojan.tls = true;
      const injected = new ProxyNode();
      injected.id = 'bad'; injected.name = 'bad\n  - MATCH,DIRECT'; injected.server = 'bad.example.com';
      injected.port = 443; injected.method = 'aes-128-gcm'; injected.password = 'pw'; injected.proxyType = 'ss';
      const settings = new AppSettings();
      const config = ClashConfigGenerator.generate(vless, [ss, vless, vmess, trojan, injected], settings,
        7890, 9090, 'secret');
      expect(config.includes('type: ss')).assertTrue();
      expect(config.includes('type: vless')).assertTrue();
      expect(config.includes('type: vmess')).assertTrue();
      expect(config.includes('type: trojan')).assertTrue();
      expect(config.includes('grpc-service-name: "svc"')).assertTrue();
      expect(config.includes('bad\n  - MATCH,DIRECT')).assertFalse();
    });

    it('hysteria2_uri_yaml_and_generator', 0, () => {
      // 1) hysteria2:// URI 解析（含中文 percent-encoded 名称、insecure、sni、obfs、带宽）
      const uri = 'hysteria2://p@ssw0rd@sg01.example.xyz:8443/?insecure=1&sni=localhost'
        + '&obfs=salamander&obfs-password=abc123&up=114&down=514&pinSHA256=deadbeef'
        + '#%E6%96%B0%E5%8A%A0%E5%9D%A101';
      const n = ProxyNode.fromUri(uri, 't', 'id1');
      expect(n !== null).assertTrue();
      expect(n?.name ?? '').assertEqual('新加坡01');
      expect(n?.password ?? '').assertEqual('p@ssw0rd');
      expect(n?.proxyType ?? '').assertEqual('hysteria2');
      expect(n?.port ?? 0).assertEqual(8443);
      expect(n?.skipCertVerify ?? false).assertTrue();
      expect(n?.servername ?? '').assertEqual('localhost');
      expect(n?.obfs ?? '').assertEqual('salamander');
      expect(n?.obfsParam ?? '').assertEqual('abc123');
      expect(n?.hyUp ?? '').assertEqual('114');
      expect(n?.hyDown ?? '').assertEqual('514');
      expect(n?.clientFingerprint ?? '').assertEqual('deadbeef');
      // 2) 配置生成：键名 sni/fingerprint/obfs-password/up/down 正确
      const line = ClashConfigGenerator.proxyYamlLine(n!);
      expect(line.includes('type: hysteria2')).assertTrue();
      expect(line.includes('sni: "localhost"')).assertTrue();
      expect(line.includes('fingerprint: "deadbeef"')).assertTrue();
      expect(line.includes('obfs-password: "abc123"')).assertTrue();
      expect(line.includes('up: "114"')).assertTrue();
      expect(line.includes('down: "514"')).assertTrue();
      expect(line.includes('servername:')).assertFalse();
      expect(line.includes('client-fingerprint:')).assertFalse();
      // 3) Clash YAML 流式条目解析 + 缓存往返
      const yaml = 'proxies:\n'
        + '  - { name: \u0027剩余流量：596.51 GB\u0027, server: sg01.example.xyz, port: 8443, udp: true,'
        + ' skip-cert-verify: true, sni: localhost, type: hysteria2, password: e73cc1c7-545d-437b-b328-7490b0f06d28 }\n';
      const parsed = SubscriptionParser.parse(yaml, 'hy');
      expect(parsed.length).assertEqual(1);
      expect(parsed[0].proxyType).assertEqual('hysteria2');
      expect(parsed[0].servername).assertEqual('localhost');
      const cached = YamlMerger.toYaml(YamlMerger.merge([yaml], 'hy', ''));
      const reread = SubscriptionParser.parse(cached, 'hy2');
      expect(reread.length).assertEqual(1);
      expect(reread[0].password).assertEqual('e73cc1c7-545d-437b-b328-7490b0f06d28');
      expect(reread[0].skipCertVerify).assertTrue();
      // 4) 缺 password 的 hy2 节点必须被拒绝
      expect(ProxyNode.fromUri('hysteria2://@x.example.com:443/', 't', 'id2') === null).assertTrue();
    });

    it('subscription_url_redact', 0, () => {
      expect(SubscriptionFetchPolicy.redactUrl('https://sub.example.com/path?token=abc'))
        .assertEqual('sub.example.com');
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://a.com/x')).assertTrue();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('ftp://a.com')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('http://a.com/x')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://localhost/x')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://127.0.0.1/x')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://192.168.1.1/x')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://a.com:8443/x')).assertFalse();
    });
  });
}
