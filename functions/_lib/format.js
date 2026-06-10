/**
 * Client format negotiation.
 *
 * Resolves the output format from an explicit `?format=` override first, then
 * falls back to User-Agent sniffing. The UA signatures mirror the conventional
 * identifiers each client sends, matching how upstream subscription services
 * route formats.
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

/** Normalize an explicit format string to a canonical identifier, or "". */
export function normalizeFormat(value) {
	if (typeof value !== "string") {
		return "";
	}
	return ALIASES[value.trim().toLowerCase()] || "";
}

/** Infer a format from a User-Agent header. */
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
 * Resolve the final format: explicit query override > User-Agent > default.
 */
export function negotiateFormat(explicit, userAgent, fallback) {
	return normalizeFormat(explicit) || formatFromUserAgent(userAgent) || fallback;
}
