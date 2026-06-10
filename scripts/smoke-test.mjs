import { buildNodes } from "../functions/_lib/protocol.js";
import { resolveConfig } from "../functions/_lib/config.js";
import { generate } from "../functions/_lib/templates/index.js";

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
console.assert(nodes.length === 4, "expected 4 nodes");

const ss = nodes.find((n) => n.protocol === "shadowsocks");
console.assert(ss.password === "SERVERPW:USERPW", "ss2022 password should be server:user, got " + ss.password);
console.assert(ss.server === "203.0.113.10", "server should be public ip");

const vmess = nodes.find((n) => n.protocol === "vmess-ws");
console.assert(vmess.wsPathWithEarlyData === "/wspath?ed=2048", "ws path early data, got " + vmess.wsPathWithEarlyData);
console.assert(vmess.wsHost === "vm.example.com", "ws host from domain, got " + vmess.wsHost);

const reality = nodes.find((n) => n.protocol === "vless-reality");
console.assert(reality.realityPublicKey === "PBKEY123", "reality pbk from meta");
console.assert(reality.name === "tokyo", "node name should hide username, got " + reality.name);

for (const fmt of ["clash", "singbox", "surge", "quantumultx", "shadowrocket", "universal"]) {
	const { contentType, body } = await generate(fmt, nodes, config, raw);
	console.log(`\n===== ${fmt} (${contentType}) len=${body.length} =====`);
	console.log(body.slice(0, 400));
	if (fmt === "singbox") {
		JSON.parse(body);
		console.log("singbox JSON valid");
	}
}
console.log("\nALL CHECKS DONE");
