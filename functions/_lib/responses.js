/**
 * Unified HTTP response construction.
 *
 * Centralizing response shaping keeps security headers (nosniff), cache policy,
 * and error semantics consistent across every code path in the gateway.
 */

import { CONTENT_TYPE } from "./constants.js";

const SECURITY_HEADERS = Object.freeze({
	"x-content-type-options": "nosniff",
});

/** A successful subscription response with the negotiated content type. */
export function subscriptionResponse(body, contentType, cacheControl, userinfo) {
	const headers = {
		"content-type": contentType || CONTENT_TYPE.PLAIN,
		"cache-control": cacheControl || "no-store",
		...SECURITY_HEADERS,
	};
	if (userinfo) {
		// Standard quota/expiry meter consumed by Shadowrocket, Clash Verge, etc.
		headers["subscription-userinfo"] = userinfo;
	}
	return new Response(body, {
		status: 200,
		headers,
	});
}

function errorResponse(status, message) {
	return new Response(message, {
		status,
		headers: {
			"content-type": CONTENT_TYPE.PLAIN,
			"cache-control": "no-store",
			...SECURITY_HEADERS,
		},
	});
}

/** 500: the gateway itself is misconfigured (missing VPS base URL / token). */
export function misconfiguredResponse() {
	return errorResponse(500, "Service unavailable");
}

/** 502: the VPS data API failed or returned an unusable payload. */
export function upstreamErrorResponse() {
	return errorResponse(502, "Bad gateway");
}
