/**
 * Protocol detection and node normalization.
 *
 * Translates the raw, user-scoped sing-box inbound slices returned by the VPS
 * into a flat list of normalized nodes that the link builders and config
 * generators can consume without ever touching upstream schema quirks again.
 *
 * The detection rules and field defaults intentionally mirror the upstream
 * Tangfffyx/sing-box export flow (lib/70_export.sh + JQ_DETECT_PROTOCOL) so the
 * nodes we emit behave identically to the upstream-generated ones.
 */

import { PROTOCOL } from "./constants.js";

const DEFAULT_REALITY_SNI = "www.icloud.com";
const DEFAULT_SS_METHOD = "2022-blake3-aes-128-gcm";
const DEFAULT_FLOW = "xtls-rprx-vision";
const WS_EARLY_DATA = "?ed=2048";

/** Mirror upstream JQ_DETECT_PROTOCOL on a single inbound object. */
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

/** Display name: the node part before `@`, hiding the business username. */
function nodePart(fullName) {
	return fullName.includes("@") ? fullName.split("@")[0] : fullName;
}

/** Resolve the WebSocket host for a ws node, preferring the operator domain. */
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
 * Shadowsocks-2022 password assembly.
 *
 * Upstream emits `serverPassword:userPassword` when the inbound carries its own
 * password that differs from the user's; otherwise just the user password.
 */
function shadowsocksPassword(inbound, userPassword) {
	const serverPassword = String(inbound?.password || "");
	if (serverPassword && serverPassword !== userPassword) {
		return `${serverPassword}:${userPassword}`;
	}
	return userPassword;
}

/**
 * Build the normalized node list for the whole raw payload.
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
