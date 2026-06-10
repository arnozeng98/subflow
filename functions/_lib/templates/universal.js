/**
 * Universal subscription generator.
 *
 * Emits a base64-encoded, newline-joined list of protocol share links. This is
 * the most broadly compatible format: V2RayN, NekoBox, Shadowrocket and most
 * generic clients import it directly, including for protocols (Reality, TUIC)
 * that the rule-based formats cannot represent.
 */

import { CONTENT_TYPE } from "../constants.js";
import { base64NoWrap, buildLink } from "../links.js";

export function generateUniversal(nodes) {
	const links = nodes.map(buildLink).filter(Boolean);
	const body = base64NoWrap(links.join("\n"));
	return { contentType: CONTENT_TYPE.PLAIN, body };
}
