import assert from "node:assert/strict";
import test from "node:test";

import { resolveConfig } from "../../cloudflare/functions/_lib/config.js";
import {
	misconfiguredResponse,
	subscriptionResponse,
	upstreamErrorResponse,
} from "../../cloudflare/functions/_lib/responses.js";


test("订阅响应默认禁止浏览器和共享代理缓存", () => {
	const config = resolveConfig({
		VPS_API_BASE_URL: "https://api.example.com",
		VPS_API_BEARER_TOKEN: "test-token",
	});

	assert.equal(config.responseCacheControl, "no-store");

	const response = subscriptionResponse(
		"subscription-body",
		"text/plain; charset=utf-8",
		config.responseCacheControl,
		"",
	);
	assert.equal(response.headers.get("cache-control"), "no-store");
});


test("运维人员仍可显式覆盖响应缓存策略", () => {
	const config = resolveConfig({
		VPS_API_BASE_URL: "https://api.example.com",
		VPS_API_BEARER_TOKEN: "test-token",
		RESPONSE_CACHE_CONTROL: "private, max-age=60",
	});

	assert.equal(config.responseCacheControl, "private, max-age=60");
});


test("网关错误响应使用中文且禁止缓存", async () => {
	const misconfigured = misconfiguredResponse();
	assert.equal(misconfigured.status, 500);
	assert.equal(misconfigured.headers.get("cache-control"), "no-store");
	assert.equal(await misconfigured.text(), "服务暂时不可用");

	const upstream = upstreamErrorResponse();
	assert.equal(upstream.status, 502);
	assert.equal(upstream.headers.get("cache-control"), "no-store");
	assert.equal(await upstream.text(), "上游服务不可用");
});