/**
 * 客户端格式协商。
 *
 * 优先根据显式的 `?format=` 参数进行覆盖，若未提供则回退到对 User-Agent 的探嗅。
 * 这些 UA 特征与各客户端惯例上发送的标识符一致，与上游订阅服务路由格式的方式相匹配。
 */

import { FORMAT } from "./constants.js";

const ALIASES = {
	clash: FORMAT.CLASH,
	mihomo: FORMAT.CLASH,
	"clash.meta": FORMAT.CLASH,
	clashmeta: FORMAT.CLASH,
	singbox: FORMAT.SINGBOX,
	"sing-box": FORMAT.SINGBOX,
	surge: FORMAT.SURGE,
	quantumultx: FORMAT.QUANTUMULTX,
	qx: FORMAT.QUANTUMULTX,
	quantumult: FORMAT.QUANTUMULTX,
	shadowrocket: FORMAT.SHADOWROCKET,
	universal: FORMAT.UNIVERSAL,
	v2ray: FORMAT.UNIVERSAL,
	v2rayn: FORMAT.UNIVERSAL,
	base64: FORMAT.UNIVERSAL,
};

/** 将显式的格式字符串规范化为标准标识符，若无法识别则返回 ""。 */
export function normalizeFormat(value) {
	if (typeof value !== "string") {
		return "";
	}
	return ALIASES[value.trim().toLowerCase()] || "";
}

/** 从 User-Agent 请求头推断出格式。 */
export function formatFromUserAgent(userAgent) {
	const ua = (userAgent || "").toLowerCase();
	if (!ua) {
		return "";
	}
	if (ua.includes("clash") || ua.includes("mihomo") || ua.includes("stash")) {
		return FORMAT.CLASH;
	}
	if (ua.includes("sing-box") || ua.includes("singbox")) {
		return FORMAT.SINGBOX;
	}
	if (ua.includes("quantumult%20x") || ua.includes("quantumult x") || ua.includes("quantumult")) {
		return FORMAT.QUANTUMULTX;
	}
	if (ua.includes("shadowrocket")) {
		return FORMAT.SHADOWROCKET;
	}
	if (ua.includes("surge")) {
		return FORMAT.SURGE;
	}
	return "";
}

/**
 * 确定最终格式：优先级为显式查询参数覆盖 > User-Agent > 默认值。
 */
export function negotiateFormat(explicit, userAgent, fallback) {
	return normalizeFormat(explicit) || formatFromUserAgent(userAgent) || fallback;
}
