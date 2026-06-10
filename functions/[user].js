/**
 * Public subscription gateway (Cloudflare Pages Function).
 *
 * This is the entry point and orchestrator only. It validates the username,
 * fetches the user's raw node data from the VPS data API, negotiates the client
 * format, and delegates full configuration generation to the `_lib` modules.
 *
 * All assembly happens here on Cloudflare: the VPS exposes data, this layer
 * builds every client config from official, continuously-updated rule sources.
 * Unknown users fall through to Cloudflare's native 404 so enumeration attempts
 * receive no business-specific signal.
 */

import { USERNAME_PATTERN } from "./_lib/constants.js";
import { resolveConfig, hasUpstream } from "./_lib/config.js";
import { fetchRawPayload } from "./_lib/raw-client.js";
import { buildNodes } from "./_lib/protocol.js";
import { negotiateFormat } from "./_lib/format.js";
import { generate } from "./_lib/templates/index.js";
import {
	subscriptionResponse,
	misconfiguredResponse,
	upstreamErrorResponse,
} from "./_lib/responses.js";

export async function onRequestGet(context) {
	const { request, env, params, next, waitUntil } = context;

	const username = typeof params?.user === "string" ? params.user.trim() : "";
	if (!username || !USERNAME_PATTERN.test(username)) {
		return next();
	}

	const config = resolveConfig(env);
	if (!hasUpstream(config)) {
		return misconfiguredResponse();
	}

	let raw;
	try {
		const result = await fetchRawPayload(config, username, request);
		if (result.kind === "not-found") {
			return next();
		}
		if (result.kind !== "ok") {
			return upstreamErrorResponse();
		}
		raw = result.data;
	} catch {
		return upstreamErrorResponse();
	}

	const nodes = buildNodes(raw);
	if (nodes.length === 0) {
		return next();
	}

	const url = new URL(request.url);
	const format = negotiateFormat(
		url.searchParams.get("format"),
		request.headers.get("user-agent"),
		config.defaultFormat,
	);

	try {
		const { contentType, body } = await generate(format, nodes, config, raw, { waitUntil });
		return subscriptionResponse(body, contentType, config.responseCacheControl);
	} catch {
		return upstreamErrorResponse();
	}
}
