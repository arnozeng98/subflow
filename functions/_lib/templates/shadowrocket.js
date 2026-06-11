/**
 * Shadowrocket subscription generator.
 *
 * Shadowrocket natively imports the base64 share-link list and supports every
 * protocol subflow emits (Reality, VLESS, VMess, Shadowsocks, Trojan, TUIC,
 * AnyTLS), unlike the Surge/QuantumultX rule formats.
 *
 * The traffic quota and expiry are delivered via the `Subscription-Userinfo`
 * HTTP response header (set in the orchestrator), which Shadowrocket renders as
 * a native, auto-formatted (GiB/MiB/KiB) meter with an expiry date — so this
 * generator only emits the URI list. Rules are configured client-side or via a
 * separate remote config.
 */

import { CONTENT_TYPE } from "../constants.js";
import { base64NoWrap, buildLink } from "../links.js";

export function generateShadowrocket(nodes) {
	const links = nodes.map(buildLink).filter(Boolean);
	const body = base64NoWrap(links.join("\n"));
	return { contentType: CONTENT_TYPE.PLAIN, body };
}
