/**
 * 完整的 Quantumult X 配置生成器。
 *
 * 输出 [server_local] 节点定义、由 blackmatrix7/ios_rule_script（QuantumultX 列表）
 * 支撑的 [filter_remote] 规则订阅，以及 [policy] 和 [general] 区段。
 * Quantumult X 无法表达 TUIC，因此该类节点会被跳过。
 */

import { CONTENT_TYPE, PROTOCOL } from "../constants.js";

/** 构造单条 Quantumult X server 定义行；若协议不受支持则返回 ""。 */
function serverLine(node) {
	switch (node.protocol) {
		case PROTOCOL.VLESS_REALITY:
			return `vless=${node.server}:${node.port}, method=none, password=${node.uuid}, obfs=over-tls, obfs-host=${node.sni}, reality-base64-pubkey=${node.realityPublicKey || "PUBLIC_KEY_MISSING"}, reality-hex-shortid=${node.realityShortId}, vless-flow=${node.flow}, udp-relay=true, tag=${node.name}`;
		case PROTOCOL.VLESS_WS:
			return `vless=${node.server}:443, method=none, password=${node.uuid}, obfs=wss, obfs-host=${node.wsHost}, obfs-uri=${node.wsPathWithEarlyData}, fast-open=false, udp-relay=true, tag=${node.name}`;
		case PROTOCOL.VMESS_WS:
			return `vmess=${node.server}:443, method=chacha20-poly1305, password=${node.uuid}, obfs=wss, obfs-host=${node.wsHost}, obfs-uri=${node.wsPathWithEarlyData}, fast-open=false, udp-relay=true, tag=${node.name}`;
		case PROTOCOL.ANYTLS:
			return `anytls=${node.server}:${node.port}, password=${node.password}, over-tls=true, tls-host=${node.sni}, udp-relay=true, tag=${node.name}`;
		case PROTOCOL.SHADOWSOCKS:
			return `shadowsocks=${node.server}:${node.port}, method=${node.method}, password=${node.password}, udp-relay=true, tag=${node.name}`;
		case PROTOCOL.TROJAN:
			return `trojan=${node.server}:${node.port}, password=${node.password}, over-tls=true, tls-host=${node.sni}, tls-verification=false, fast-open=false, udp-relay=true, tag=${node.name}`;
		default:
			return "";
	}
}

// 生成单条 [filter_remote] 订阅行：拼接出对应规则列表的 URL，并用 force-policy
// 将其绑定到指定策略组，同时设置每日更新（update-interval=86400）。
function filterRemote(base, name, policy) {
	const url = `${base}/QuantumultX/${name}/${name}.list`;
	return `${url}, tag=${name}, force-policy=${policy}, update-interval=86400, opt-parser=true, enabled=true`;
}

export function generateQuantumultX(nodes, config) {
	const servers = nodes.map(serverLine).filter(Boolean);
	const base = config.ruleSources.blackmatrix7Base;

	const serverSection = ["[server_local]", ...servers].join("\n");

	const policySection = [
		"[policy]",
		"static=🚀 节点选择, 🎯 全球直连, server-tag-regex=.*",
		"static=📲 电报信息, 🚀 节点选择, 🎯 全球直连",
		"static=🍎 苹果服务, 🎯 全球直连, 🚀 节点选择",
		"static=🛑 全球拦截, reject, direct",
		"static=🐟 漏网之鱼, 🚀 节点选择, 🎯 全球直连",
	].join("\n");

	const filterSection = [
		"[filter_remote]",
		filterRemote(base, "Advertising", "🛑 全球拦截"),
		filterRemote(base, "Apple", "🍎 苹果服务"),
		filterRemote(base, "Telegram", "📲 电报信息"),
		filterRemote(base, "Global", "🚀 节点选择"),
		filterRemote(base, "China", "🎯 全球直连"),
		filterRemote(base, "ChinaMax", "🎯 全球直连"),
	].join("\n");

	const filterLocal = ["[filter_local]", "geoip, cn, 🎯 全球直连", "final, 🐟 漏网之鱼"].join("\n");

	const general = [
		"[general]",
		"network_check_url=http://www.gstatic.com/generate_204",
		"server_check_url=http://www.gstatic.com/generate_204",
		"geo_location_check=disabled",
	].join("\n");

	const body = [
		`# Subflow profile: ${config.profileName}`,
		general,
		serverSection,
		policySection,
		filterSection,
		filterLocal,
		"",
	].join("\n\n");

	return { contentType: CONTENT_TYPE.PLAIN, body };
}
