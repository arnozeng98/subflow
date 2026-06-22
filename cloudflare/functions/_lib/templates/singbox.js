/**
 * 完整的 sing-box 配置生成器。
 *
 * 生成一个完整的配置对象（log、dns、inbounds、outbounds、route），并在返回前
 * 通过 JSON 往返解析（round-trip）进行校验。路由规则由 SagerNet 官方预编译的
 * 规则集（.srs）远程引用提供，这样客户端能从上游源持续更新 geosite/geoip 数据。
 */

import { CONTENT_TYPE, PROTOCOL } from "../constants.js";

// 构造 TLS 配置块：始终启用 uTLS 并伪装为 chrome 指纹；可选地启用跳过证书
// 校验（insecure）、指定 alpn，以及启用 Reality（填入公钥与 short_id）。
function tlsBlock(serverName, { reality, insecure, alpn } = {}) {
	const tls = {
		enabled: true,
		server_name: serverName,
		utls: { enabled: true, fingerprint: "chrome" },
	};
	if (insecure) {
		tls.insecure = true;
	}
	if (alpn) {
		tls.alpn = alpn;
	}
	if (reality) {
		tls.reality = {
			enabled: true,
			public_key: reality.publicKey || "PUBLIC_KEY_MISSING",
			short_id: reality.shortId || "",
		};
	}
	return tls;
}

function wsTransport(node) {
	return {
		type: "ws",
		path: node.wsPath,
		headers: { Host: node.wsHost },
		max_early_data: 2048,
		early_data_header_name: "Sec-WebSocket-Protocol",
	};
}

/** 构造单个 outbound（出站）对象；若协议不受支持则返回 null。 */
function outbound(node) {
	switch (node.protocol) {
		case PROTOCOL.VLESS_REALITY:
			return {
				type: "vless",
				tag: node.name,
				server: node.server,
				server_port: node.port,
				uuid: node.uuid,
				flow: node.flow,
				tls: tlsBlock(node.sni, {
					reality: { publicKey: node.realityPublicKey, shortId: node.realityShortId },
				}),
			};
		case PROTOCOL.VLESS_WS:
			return {
				type: "vless",
				tag: node.name,
				server: node.server,
				server_port: 443,
				uuid: node.uuid,
				tls: tlsBlock(node.wsHost),
				transport: wsTransport(node),
			};
		case PROTOCOL.VMESS_WS:
			return {
				type: "vmess",
				tag: node.name,
				server: node.server,
				server_port: 443,
				uuid: node.uuid,
				alter_id: 0,
				security: "auto",
				tls: tlsBlock(node.wsHost),
				transport: wsTransport(node),
			};
		case PROTOCOL.ANYTLS:
			return {
				type: "anytls",
				tag: node.name,
				server: node.server,
				server_port: node.port,
				password: node.password,
				tls: tlsBlock(node.sni, { insecure: true, alpn: ["h2", "http/1.1"] }),
			};
		case PROTOCOL.SHADOWSOCKS:
			return {
				type: "shadowsocks",
				tag: node.name,
				server: node.server,
				server_port: node.port,
				method: node.method,
				password: node.password,
			};
		case PROTOCOL.TROJAN:
			return {
				type: "trojan",
				tag: node.name,
				server: node.server,
				server_port: node.port,
				password: node.password,
				tls: tlsBlock(node.sni, { insecure: true, alpn: ["h2", "http/1.1"] }),
			};
		case PROTOCOL.TUIC:
			return {
				type: "tuic",
				tag: node.name,
				server: node.server,
				server_port: node.port,
				uuid: node.uuid,
				password: node.password,
				congestion_control: "bbr",
				tls: tlsBlock(node.sni, { insecure: true, alpn: ["h3"] }),
			};
		default:
			return null;
	}
}

// 构造单个远程规则集定义：采用 binary 格式的 .srs 文件，下载流量走
// "🚀 节点选择"（download_detour），避免在未联网时因直连下载规则集而失败。
function remoteRuleSet(tag, url) {
	return {
		tag,
		type: "remote",
		format: "binary",
		url,
		download_detour: "🚀 节点选择",
	};
}

export function generateSingbox(nodes, config, baseTemplate) {
	const outbounds = nodes.map(outbound).filter(Boolean);
	const proxyTags = outbounds.map((item) => item.tag);

	const geositeBase = config.ruleSources.singboxGeositeBase;
	const geoipBase = config.ruleSources.singboxGeoipBase;

	const document = {
		log: { level: "info", timestamp: true },
		dns: {
			servers: [
				{ tag: "google", address: "https://8.8.8.8/dns-query", detour: "🚀 节点选择" },
				{ tag: "local", address: "https://223.5.5.5/dns-query", detour: "direct" },
				{ tag: "block", address: "rcode://success" },
			],
			rules: [
				{ rule_set: "geosite-cn", server: "local" },
				{ clash_mode: "direct", server: "local" },
				{ clash_mode: "global", server: "google" },
			],
			final: "google",
			strategy: "prefer_ipv4",
		},
		inbounds: [
			{
				type: "tun",
				tag: "tun-in",
				address: ["172.18.0.1/30", "fdfe:dcba:9876::1/126"],
				auto_route: true,
				strict_route: true,
				stack: "mixed",
				sniff: true,
			},
			{ type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080, sniff: true },
		],
		outbounds: [
			{ type: "selector", tag: "🚀 节点选择", outbounds: ["♻️ 自动选择", ...proxyTags], default: "♻️ 自动选择" },
			{
				type: "urltest",
				tag: "♻️ 自动选择",
				outbounds: proxyTags,
				url: "https://www.gstatic.com/generate_204",
				interval: "5m",
				tolerance: 50,
			},
			...outbounds,
			{ type: "direct", tag: "direct" },
			{ type: "block", tag: "block" },
			{ type: "dns", tag: "dns-out" },
		],
		route: {
			rule_set: [
				remoteRuleSet("geosite-cn", `${geositeBase}/geosite-cn.srs`),
				remoteRuleSet("geosite-geolocation-!cn", `${geositeBase}/geosite-geolocation-!cn.srs`),
				remoteRuleSet("geosite-category-ads-all", `${geositeBase}/geosite-category-ads-all.srs`),
				remoteRuleSet("geoip-cn", `${geoipBase}/geoip-cn.srs`),
			],
			rules: [
				{ action: "sniff" },
				{ protocol: "dns", action: "hijack-dns" },
				{ rule_set: "geosite-category-ads-all", outbound: "block" },
				{ clash_mode: "direct", outbound: "direct" },
				{ clash_mode: "global", outbound: "🚀 节点选择" },
				{ rule_set: ["geoip-cn", "geosite-cn"], outbound: "direct" },
				{ rule_set: "geosite-geolocation-!cn", outbound: "🚀 节点选择" },
			],
			final: "🚀 节点选择",
			auto_detect_interface: true,
		},
		experimental: {
			clash_api: { external_controller: "127.0.0.1:9090" },
			cache_file: { enabled: true },
		},
	};

	let body;
	if (baseTemplate) {
		try {
			const parsed = JSON.parse(baseTemplate);
			parsed.outbounds = document.outbounds;
			body = JSON.stringify(parsed, null, 2);
		} catch {
			body = JSON.stringify(document, null, 2);
		}
	} else {
		body = JSON.stringify(document, null, 2);
	}

	// 往返解析校验：绝不输出客户端无法解析的配置。
	JSON.parse(body);
	return { contentType: CONTENT_TYPE.JSON, body };
}
