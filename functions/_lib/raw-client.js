/**
 * Client for the VPS private data API.
 *
 * Responsible only for transport: build the URL, attach the bearer token, apply
 * a timeout, and classify the result. It never interprets the payload beyond
 * JSON parsing so the calling code can decide how to react to each outcome.
 */

/** @typedef {{ kind: "ok", data: object } | { kind: "not-found" } | { kind: "error" }} RawResult */

function buildRawUrl(config, username) {
	const encoded = encodeURIComponent(username);
	const path = config.rawPathTemplate
		.replaceAll("{user}", encoded)
		.replaceAll("{username}", encoded)
		.replace(/^\//, "");
	return `${config.apiBaseUrl}/${path}`;
}

/**
 * Fetch the raw, user-scoped payload from the VPS.
 *
 * @returns {Promise<RawResult>}
 */
export async function fetchRawPayload(config, username, request) {
	const controller = new AbortController();
	const timeoutId = setTimeout(() => controller.abort(), config.requestTimeoutMs);

	try {
		const headers = {
			authorization: `Bearer ${config.bearerToken}`,
			accept: "application/json",
		};
		const userAgent = request?.headers?.get("user-agent");
		if (userAgent) {
			headers["user-agent"] = userAgent;
		}

		const response = await fetch(buildRawUrl(config, username), {
			method: "GET",
			headers,
			signal: controller.signal,
		});

		if (response.status === 404) {
			return { kind: "not-found" };
		}
		if (!response.ok) {
			return { kind: "error" };
		}

		const data = await response.json();
		if (!data || !Array.isArray(data.inbounds) || data.inbounds.length === 0) {
			return { kind: "not-found" };
		}
		return { kind: "ok", data };
	} catch {
		return { kind: "error" };
	} finally {
		clearTimeout(timeoutId);
	}
}
