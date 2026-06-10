/**
 * Protocol share-link builders.
 *
 * One function per protocol, mirroring the upstream Tangfffyx/sing-box V2RayN
 * link builders so the links we emit are byte-compatible with what users already
 * expect. These power the "universal" base64 subscription and are reused by the
 * per-platform generators where a raw URI is the most reliable representation.
 */

/** URL-encode a component (RFC 3986, encodeURIComponent already does this). */
export function urlEncode(value) {
	return encodeURIComponent(value ?? "");
}

/** UTF-8 safe, unwrapped base64 (btoa is latin1-only, so encode bytes first). */
export function base64NoWrap(value) {
	const bytes = new TextEncoder().encode(value ?? "");
	let binary = "";
	for (const byte of bytes) {
		binary += String.fromCharCode(byte);
	}
	return btoa(binary);
}

export function buildVlessRealityLink(node) {
	const pbk = urlEncode(node.realityPublicKey || "PUBLIC_KEY_MISSING");
	return (
		`vless://${node.uuid}@${node.server}:${node.port}` +
		`?encryption=none&flow=${urlEncode(node.flow)}&security=reality` +
		`&sni=${urlEncode(node.sni)}&fp=chrome&pbk=${pbk}` +
		`&sid=${urlEncode(node.realityShortId)}&type=tcp#${urlEncode(node.name)}`
	);
}

export function buildVlessWsLink(node) {
	const host = urlEncode(node.wsHost);
	return (
		`vless://${node.uuid}@${node.server}:443` +
		`?encryption=none&security=tls&sni=${host}&type=ws` +
		`&host=${host}&path=${urlEncode(node.wsPathWithEarlyData)}#${urlEncode(node.name)}`
	);
}

export function buildVmessWsLink(node) {
	const payload = {
		v: "2",
		ps: node.name,
		add: node.server,
		port: "443",
		id: node.uuid,
		aid: "0",
		scy: "auto",
		net: "ws",
		type: "none",
		host: node.wsHost,
		path: node.wsPathWithEarlyData,
		tls: "tls",
		sni: node.wsHost,
	};
	return `vmess://${base64NoWrap(JSON.stringify(payload))}`;
}

export function buildAnytlsLink(node) {
	return (
		`anytls://${node.password}@${node.server}:${node.port}` +
		`?sni=${urlEncode(node.sni)}&fp=chrome&alpn=${urlEncode("h2,http/1.1")}` +
		`&allowInsecure=1#${urlEncode(node.name)}`
	);
}

export function buildShadowsocksLink(node) {
	const userinfo = base64NoWrap(`${node.method}:${node.password}`);
	return `ss://${userinfo}@${node.server}:${node.port}#${urlEncode(node.name)}`;
}

export function buildTrojanLink(node) {
	return (
		`trojan://${urlEncode(node.password)}@${node.server}:${node.port}` +
		`?security=tls&sni=${urlEncode(node.sni)}&alpn=${urlEncode("h2,http/1.1")}` +
		`&allowInsecure=1#${urlEncode(node.name)}`
	);
}

export function buildTuicLink(node) {
	return (
		`tuic://${node.uuid}:${urlEncode(node.password)}@${node.server}:${node.port}` +
		`?sni=${urlEncode(node.sni)}&alpn=${urlEncode("h3")}` +
		`&allow_insecure=1&congestion_control=bbr#${urlEncode(node.name)}`
	);
}

const BUILDERS = {
	"vless-reality": buildVlessRealityLink,
	"vless-ws": buildVlessWsLink,
	"vmess-ws": buildVmessWsLink,
	anytls: buildAnytlsLink,
	shadowsocks: buildShadowsocksLink,
	trojan: buildTrojanLink,
	tuic: buildTuicLink,
};

/** Build a share link for any supported node, or "" for unsupported protocols. */
export function buildLink(node) {
	const builder = BUILDERS[node.protocol];
	return builder ? builder(node) : "";
}
