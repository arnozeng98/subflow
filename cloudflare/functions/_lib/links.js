/**
 * 协议分享链接构建器。
 *
 * 每种协议对应一个函数，与随包发布的 sing-box 管理器中的 V2RayN 链接构建器保持一致，
 * 以确保我们输出的链接与用户已经熟悉的格式逐字节兼容。这些函数支撑着“universal”
 * base64 订阅，并被各平台生成器在原始 URI 是最可靠表示形式的场景下复用。
 */

/** 对单个 URL 组件进行编码（遵循 RFC 3986，encodeURIComponent 本身已按此处理）。 */
export function urlEncode(value) {
	return encodeURIComponent(value ?? "");
}

/** UTF-8 安全、不换行的 base64（btoa 仅支持 latin1，所以需先把字符串编码为字节）。 */
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

/** 为任意受支持的节点构建分享链接；对于不支持的协议则返回 ""。 */
export function buildLink(node) {
	const builder = BUILDERS[node.protocol];
	return builder ? builder(node) : "";
}
