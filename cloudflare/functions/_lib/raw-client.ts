/**
 * VPS 私有数据 API 客户端：认证、超时与响应分类。
 */
import { isRawPayload, isRecord } from "./types.js";
import type { Config, RawPayload } from "./types.js";

export type RawResult = { kind: "ok"; data: RawPayload } | { kind: "not-found" } | { kind: "error" };

function buildRawUrl(config: Config, username: string) {
	const encoded = encodeURIComponent(username);
	const path = config.rawPathTemplate
		.replaceAll("{user}", encoded)
		.replaceAll("{username}", encoded)
		.replace(/^\//, "");
	return `${config.apiBaseUrl}/${path}`;
}

export async function fetchRawPayload(config: Config, username: string): Promise<RawResult> {
	const controller = new AbortController();
	const timeoutId = setTimeout(() => controller.abort(), config.requestTimeoutMs);
	try {
		const headers = new Headers({
			authorization: `Bearer ${config.bearerToken}`,
			accept: "application/json",
		});
		const response = await fetch(buildRawUrl(config, username), {
			method: "GET",
			headers,
			redirect: "manual",
			signal: controller.signal,
		});
		if (response.status === 404) return { kind: "not-found" };
		if (!response.ok) return { kind: "error" };
		const data: unknown = await response.json();
		if (!isRecord(data) || data.schema_version !== 1) return { kind: "error" };
		if (!Array.isArray(data.inbounds) || data.inbounds.length === 0) {
			return { kind: "not-found" };
		}
		if (!isRawPayload(data)) return { kind: "error" };
		return { kind: "ok", data };
	} catch {
		return { kind: "error" };
	} finally {
		clearTimeout(timeoutId);
	}
}
