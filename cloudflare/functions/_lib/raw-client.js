/**
 * VPS 私有数据 API 的客户端。
 *
 * 它只负责传输层工作：构建 URL、附上 bearer token、施加超时，并对结果进行分类。
 * 除了 JSON 解析之外，它不会对负载做任何解读，从而让调用方自行决定如何应对每种结果。
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
 * 从 VPS 拉取按用户维度划分的原始负载。
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
