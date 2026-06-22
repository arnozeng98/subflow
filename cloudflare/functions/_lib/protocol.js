/**
 * 协议检测与节点规范化。
 *
 * 把 VPS 返回的、按用户维度划分的原始 sing-box 入站（inbound）片段，翻译成一个扁平的
 * 规范化节点列表，使链接构建器与配置生成器可以直接消费这些节点，而无需再次面对
 * 上游 schema 的各种怪异之处。
 *
 * 检测规则与字段默认值刻意与随包发布的 sing-box 管理器的导出流程
 *（vps/singbox lib/70_export.sh + JQ_DETECT_PROTOCOL）保持一致，以确保我们输出的节点
 * 与管理器生成的节点行为完全一致。
 */

import { PROTOCOL } from "./constants.js";

const DEFAULT_REALITY_SNI = "www.icloud.com";
const DEFAULT_SS_METHOD = "2022-blake3-aes-128-gcm";
const DEFAULT_FLOW = "xtls-rprx-vision";
const WS_EARLY_DATA = "?ed=2048";

/** 在单个入站对象上复现上游的 JQ_DETECT_PROTOCOL 检测逻辑。 */
export function detectProtocol(inbound) {
	const type = inbound?.type;
	const tls = inbound?.tls || {};
	const transport = inbound?.transport || {};

	if (type === "vless" && Boolean(tls.reality?.enabled)) {
		return PROTOCOL.VLESS_REALITY;
	}
	if (type === "anytls") {
		return PROTOCOL.ANYTLS;
	}
	if (type === "shadowsocks") {
		return PROTOCOL.SHADOWSOCKS;
	}
	if (type === "trojan") {
		return PROTOCOL.TROJAN;
	}
	if (type === "vmess" && transport.type === "ws") {
		return PROTOCOL.VMESS_WS;
	}
	if (type === "vless" && transport.type === "ws") {
		return PROTOCOL.VLESS_WS;
	}
	if (type === "tuic") {
		return PROTOCOL.TUIC;
	}
	if (type === "socks") {
		return PROTOCOL.SOCKS;
	}
	return "";
}

function userNameField(user) {
	return String(user?.name || user?.username || "");
}

/** 显示名称：取 `@` 之前的节点部分，从而隐藏业务用户名。 */
function nodePart(fullName) {
	return fullName.includes("@") ? fullName.split("@")[0] : fullName;
}

/** 为 ws 节点解析 WebSocket 主机名，优先使用运维人员配置的域名。 */
function wsHost(protocol, inbound, wsDomains) {
	if (protocol === PROTOCOL.VLESS_WS && wsDomains?.vless) {
		return wsDomains.vless;
	}
	if (protocol === PROTOCOL.VMESS_WS && wsDomains?.vmess) {
		return wsDomains.vmess;
	}
	return String(inbound?.tls?.server_name || "");
}

/**
 * Shadowsocks-2022 密码拼装。
 *
 * 当入站自带的密码与用户密码不同时，上游会输出 `serverPassword:userPassword`；
 * 否则仅输出用户密码。
 */
function shadowsocksPassword(inbound, userPassword) {
	const serverPassword = String(inbound?.password || "");
	if (serverPassword && serverPassword !== userPassword) {
		return `${serverPassword}:${userPassword}`;
	}
	return userPassword;
}

/**
 * 为整个原始负载构建规范化后的节点列表。
 *
 * @param {object} raw Raw payload from the VPS data API.
 * @returns {Array<object>} Normalized nodes.
 */
export function buildNodes(raw) {
	const server = String(raw?.public_ip || "");
	const wsDomains = raw?.ws_domains || {};
	const meta = raw?.meta || {};
	const nodes = [];

	for (const inbound of raw?.inbounds || []) {
		const protocol = detectProtocol(inbound);
		if (!protocol) {
			continue;
		}

		const tag = String(inbound?.tag || "");
		const tls = inbound?.tls || {};
		const transport = inbound?.transport || {};
		const reality = tls.reality || {};
		const listenPort = Number.parseInt(inbound?.listen_port, 10) || 0;
		const host = wsHost(protocol, inbound, wsDomains);
		const rawPath = String(transport.path || "/");

		for (const user of inbound?.users || []) {
			const fullName = userNameField(user);
			if (!fullName) {
				continue;
			}
			const userPassword = String(user?.password || "");

			nodes.push({
				name: nodePart(fullName),
				protocol,
				server,
				port: listenPort,
				uuid: String(user?.uuid || ""),
				password:
					protocol === PROTOCOL.SHADOWSOCKS
						? shadowsocksPassword(inbound, userPassword)
						: userPassword,
				method: String(inbound?.method || DEFAULT_SS_METHOD),
				flow: String(user?.flow || DEFAULT_FLOW),
				sni: String(tls.server_name || DEFAULT_REALITY_SNI),
				wsHost: host,
				wsPath: rawPath,
				wsPathWithEarlyData: rawPath.includes("?") ? rawPath : `${rawPath}${WS_EARLY_DATA}`,
				realityPublicKey: String(meta[tag]?.public_key || ""),
				realityShortId: String((reality.short_id && reality.short_id[0]) || ""),
			});
		}
	}

	return nodes;
}
