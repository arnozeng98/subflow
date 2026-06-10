/**
 * Shadowrocket subscription generator.
 *
 * Shadowrocket natively imports the base64 share-link list and supports every
 * protocol subflow emits (Reality, VLESS, VMess, Shadowsocks, Trojan, TUIC,
 * AnyTLS), unlike the Surge/QuantumultX rule formats. It also reads the
 * `STATUS`/profile headers, so we surface the user's traffic quota there.
 *
 * Rules in Shadowrocket are configured client-side or via a separate remote
 * config; the reliable, complete node delivery is this URI list.
 */

import { CONTENT_TYPE } from "../constants.js";
import { base64NoWrap, buildLink } from "../links.js";

const GiB = 1024 * 1024 * 1024;

/** Optional Subscription-Userinfo style header for quota display. */
function userinfoComment(usage) {
	if (!usage) {
		return "";
	}
	const used = (usage.used_up_bytes || 0) + (usage.used_down_bytes || 0);
	const total = (usage.quota_gb || 0) * GiB;
	if (!total) {
		return "";
	}
	return `STATUS=upload=0; download=${used}; total=${total};`;
}

export function generateShadowrocket(nodes, _config, usage) {
	const links = nodes.map(buildLink).filter(Boolean);
	const status = userinfoComment(usage);
	const lines = status ? [status, ...links] : links;
	const body = base64NoWrap(lines.join("\n"));
	return { contentType: CONTENT_TYPE.PLAIN, body };
}
