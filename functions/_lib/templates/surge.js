/**
 * Complete Surge configuration generator.
 *
 * Emits a full Surge profile: [General], [Proxy], [Proxy Group], and [Rule]
 * with RULE-SET references to blackmatrix7/ios_rule_script (Surge lists) plus a
 * GEOIP,CN tail. Surge cannot represent VLESS, so those nodes are skipped here;
 * clients needing them should use the universal subscription.
 */

import { CONTENT_TYPE, PROTOCOL } from "../constants.js";

/** Build a single Surge proxy line, or "" if Surge cannot express the node. */
function proxyLine(node) {
	switch (node.protocol) {
		case PROTOCOL.SHADOWSOCKS:
			return `${node.name} = ss, ${node.server}, ${node.port}, encrypt-method=${node.method}, password=${node.password}, udp-relay=true`;
		case PROTOCOL.TROJAN:
			return `${node.name} = trojan, ${node.server}, ${node.port}, password=${node.password}, skip-cert-verify=true, sni=${node.sni}`;
		case PROTOCOL.ANYTLS:
			return `${node.name} = anytls, ${node.server}, ${node.port}, password=${node.password}, skip-cert-verify=true, sni=${node.sni}`;
		case PROTOCOL.VMESS_WS:
			return `${node.name} = vmess, ${node.server}, 443, username=${node.uuid}, tls=true, vmess-aead=true, ws=true, ws-path=${node.wsPathWithEarlyData}, sni=${node.wsHost}, ws-headers=Host:${node.wsHost}, skip-cert-verify=false, udp-relay=true, tfo=false`;
		case PROTOCOL.TUIC:
			return `${node.name} = tuic-v5, ${node.server}, ${node.port}, password=${node.password}, sni=${node.sni}, uuid=${node.uuid}, alpn=h3, ecn=true`;
		default:
			return "";
	}
}

function ruleSet(base, platform, name, policy) {
	return `RULE-SET,${base}/${platform}/${name}/${name}.list,${policy}`;
}

export function generateSurge(nodes, config) {
	const proxies = nodes.map(proxyLine).filter(Boolean);
	const names = nodes.filter((node) => proxyLine(node)).map((node) => node.name);
	const base = config.ruleSources.blackmatrix7Base;
	const platform = "Surge";

	const selectMembers = ["♻️ 自动选择", "DIRECT", ...names].join(", ");
	const autoMembers = names.join(", ");

	const general = [
		"[General]",
		"loglevel = notify",
		"dns-server = 223.5.5.5, 119.29.29.29, system",
		"skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, localhost, *.local",
		"ipv6 = true",
		"allow-wifi-access = false",
		"internet-test-url = http://www.apple.com/library/test/success.html",
		"proxy-test-url = http://www.gstatic.com/generate_204",
	].join("\n");

	const proxySection = ["[Proxy]", ...proxies].join("\n");

	const groupSection = [
		"[Proxy Group]",
		`🚀 节点选择 = select, ${selectMembers}`,
		`♻️ 自动选择 = url-test, ${autoMembers}, url = http://www.gstatic.com/generate_204, interval = 300, tolerance = 50`,
		`📲 电报信息 = select, 🚀 节点选择, DIRECT, ${autoMembers}`,
		`🍎 苹果服务 = select, DIRECT, 🚀 节点选择`,
		`Ⓜ️ 微软服务 = select, DIRECT, 🚀 节点选择`,
		`🛑 全球拦截 = select, REJECT, DIRECT`,
		`🎯 全球直连 = select, DIRECT, 🚀 节点选择`,
		`🐟 漏网之鱼 = select, 🚀 节点选择, DIRECT`,
	].join("\n");

	const ruleSection = [
		"[Rule]",
		ruleSet(base, platform, "Advertising", "🛑 全球拦截"),
		ruleSet(base, platform, "Apple", "🍎 苹果服务"),
		ruleSet(base, platform, "Microsoft", "Ⓜ️ 微软服务"),
		ruleSet(base, platform, "Telegram", "📲 电报信息"),
		ruleSet(base, platform, "Google", "🚀 节点选择"),
		ruleSet(base, platform, "Global", "🚀 节点选择"),
		ruleSet(base, platform, "China", "🎯 全球直连"),
		ruleSet(base, platform, "ChinaMax", "🎯 全球直连"),
		ruleSet(base, platform, "Lan", "🎯 全球直连"),
		"GEOIP,CN,🎯 全球直连",
		"FINAL,🐟 漏网之鱼,dns-failed",
	].join("\n");

	const body = [
		`# Subflow profile: ${config.profileName}`,
		general,
		proxySection,
		groupSection,
		ruleSection,
		"",
	].join("\n\n");

	return { contentType: CONTENT_TYPE.PLAIN, body };
}
