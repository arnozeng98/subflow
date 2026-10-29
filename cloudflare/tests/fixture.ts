import type { RawPayload } from "../functions/_lib/types.js";

export const raw: RawPayload = {
	schema_version: 1,
	username: "alice",
	enabled: true,
	public_ip: "203.0.113.10",
	ws_domains: { vless: "ws.example.com", vmess: "vm.example.com" },
	meta: { "reality-in": { public_key: "PBKEY123" } },
	usage: { quota_gb: 100, used_up_bytes: 1000, used_down_bytes: 2000, expire_at: "1893456000" },
	inbounds: [
		{
			tag: "reality-in", type: "vless", listen_port: 443,
			tls: { server_name: "www.icloud.com", reality: { enabled: true, short_id: ["abcd"] } },
			users: [{ name: "東京@alice", uuid: "11111111-1111-4111-8111-111111111111", flow: "xtls-rprx-vision" }],
		},
		{
			type: "shadowsocks", listen_port: 8388, method: "2022-blake3-aes-128-gcm", password: "SERVERPW",
			users: [{ name: "osaka@alice", password: "USERPW" }],
		},
		{
			type: "vmess", listen_port: 12345, transport: { type: "ws", path: "/wspath" },
			tls: { server_name: "fallback.example.com" },
			users: [{ name: "cdn@alice", uuid: "22222222-2222-4222-8222-222222222222" }],
		},
		{
			type: "vless", listen_port: "8443", transport: { type: "ws", path: "/vless?ed=1024" },
			users: [{ name: "vless-cdn@alice", uuid: "33333333-3333-4333-8333-333333333333" }],
		},
		{
			type: "tuic", listen_port: 2053, tls: { server_name: "tuic.example.com" },
			users: [{ name: "fast@alice", uuid: "44444444-4444-4444-8444-444444444444", password: "tuicpw" }],
		},
		{
			type: "trojan", listen_port: 9443, tls: { server_name: "trojan.example.com" },
			users: [{ name: "trojan@alice", password: "test+password" }],
		},
		{
			type: "anytls", listen_port: 8443, tls: { server_name: "anytls.example.com" },
			users: [{ name: 'anytls "東京"@alice', password: "anytls-test" }],
		},
	],
};

export const env = {
	VPS_API_BASE_URL: "https://vps.example.com/",
	VPS_API_BEARER_TOKEN: "test-token",
};
