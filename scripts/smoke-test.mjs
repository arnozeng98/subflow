import assert from "node:assert/strict";

import { buildNodes } from "../cloudflare/functions/_lib/protocol.js";
import { resolveConfig } from "../cloudflare/functions/_lib/config.js";
import { generate } from "../cloudflare/functions/_lib/templates/index.js";

const raw = {
	username: "alice",
	enabled: true,
	usage: { quota_gb: 100, used_up_bytes: 1e9, used_down_bytes: 2e9 },
	public_ip: "203.0.113.10",
	ws_domains: { vless: "ws.example.com", vmess: "vm.example.com" },
	meta: { "reality-in": { public_key: "PBKEY123" } },
	inbounds: [
		{
			tag: "reality-in",
			type: "vless",
			listen_port: 443,
			tls: { server_name: "www.icloud.com", reality: { enabled: true, short_id: ["abcd"] } },
			users: [{ name: "tokyo@alice", uuid: "uuid-1", flow: "xtls-rprx-vision" }],
		},
		{
			tag: "ss-in",
			type: "shadowsocks",
			listen_port: 8388,
			method: "2022-blake3-aes-128-gcm",
			password: "SERVERPW",
			users: [{ name: "osaka@alice", password: "USERPW" }],
		},
		{
			tag: "vmessws-in",
			type: "vmess",
			listen_port: 12345,
			transport: { type: "ws", path: "/wspath" },
			tls: { server_name: "fallback.example.com" },
			users: [{ name: "cdn@alice", uuid: "uuid-2" }],
		},
		{
			tag: "tuic-in",
			type: "tuic",
			listen_port: 2053,
			tls: { server_name: "tuic.example.com" },
			users: [{ name: "fast@alice", uuid: "uuid-3", password: "tuicpw" }],
		},
	],
};

const env = {
	VPS_API_BASE_URL: "https://vps.example.com",
	VPS_API_BEARER_TOKEN: "token",
};
const config = resolveConfig(env);

const nodes = buildNodes(raw);
console.log("NODES:", nodes.length);
assert.equal(nodes.length, 4, "应生成 4 个节点");

const ss = nodes.find((n) => n.protocol === "shadowsocks");
assert.ok(ss, "应生成 Shadowsocks 节点");
assert.equal(ss.password, "SERVERPW:USERPW", "SS2022 密码应为服务端密码:用户密码");
assert.equal(ss.server, "203.0.113.10", "节点地址应使用公网 IP");

const vmess = nodes.find((n) => n.protocol === "vmess-ws");
assert.ok(vmess, "应生成 VMess-WS 节点");
assert.equal(vmess.wsPathWithEarlyData, "/wspath?ed=2048", "WS 路径应包含 early data 参数");
assert.equal(vmess.wsHost, "vm.example.com", "WS Host 应使用配置域名");

const reality = nodes.find((n) => n.protocol === "vless-reality");
assert.ok(reality, "应生成 VLESS Reality 节点");
assert.equal(reality.realityPublicKey, "PBKEY123", "Reality 公钥应来自元数据");
assert.equal(reality.name, "tokyo", "节点名称不应包含业务用户名");

for (const fmt of ["clash", "singbox", "surge", "quantumultx", "shadowrocket", "universal"]) {
	const { contentType, body } = await generate(fmt, nodes, config, raw);
	console.log(`\n===== ${fmt} (${contentType}) len=${body.length} =====`);
	console.log(body.slice(0, 400));
	if (fmt === "singbox") {
		JSON.parse(body);
		console.log("sing-box JSON 有效");
	}
}
console.log("\n所有检查完成");
