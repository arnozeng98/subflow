import assert from "node:assert/strict";
import test from "node:test";

import { fetchRawPayload } from "../../cloudflare/functions/_lib/raw-client.js";


const config = {
	apiBaseUrl: "https://api.example.com",
	bearerToken: "machine-token",
	rawPathTemplate: "/internal/raw/{user}",
	requestTimeoutMs: 1000,
};


async function captureFetch(responseBody, callback) {
	const originalFetch = globalThis.fetch;
	let captured;
	globalThis.fetch = async (url, options) => {
		captured = { url, options };
		return new Response(JSON.stringify(responseBody), {
			status: 200,
			headers: { "content-type": "application/json" },
		});
	};
	try {
		await callback(() => captured);
	} finally {
		globalThis.fetch = originalFetch;
	}
}


test("回源请求只发送机器鉴权所需请求头", async () => {
	await captureFetch(
		{ schema_version: 1, inbounds: [{ type: "vless" }] },
		async (getCaptured) => {
			const result = await fetchRawPayload(config, "alice");
			assert.equal(result.kind, "ok");
			const captured = getCaptured();
			assert.equal(captured.url, "https://api.example.com/internal/raw/alice");
			assert.deepEqual(captured.options.headers, {
				authorization: "Bearer machine-token",
				accept: "application/json",
			});
		},
	);
});


test("不兼容的数据契约版本作为上游错误处理", async () => {
	await captureFetch(
		{ schema_version: 2, inbounds: [{ type: "vless" }] },
		async () => {
			const result = await fetchRawPayload(config, "alice");
			assert.deepEqual(result, { kind: "error" });
		},
	);
});