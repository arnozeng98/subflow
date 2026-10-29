import assert from "node:assert/strict";
import { test } from "node:test";
import { resolveConfig } from "../functions/_lib/config.js";
import { fetchRawPayload } from "../functions/_lib/raw-client.js";
import { fetchTemplate } from "../functions/_lib/templates/fetcher.js";
import { env, raw } from "./fixture.js";

test("raw client encodes username and sends only bearer authentication without client UA", async (t) => {
	t.mock.method(globalThis, "fetch", async (url: RequestInfo | URL, init?: RequestInit) => {
		assert.equal(url, "https://vps.example.com/raw/a%20b/a%20b");
		const headers = new Headers(init?.headers);
		assert.equal(headers.get("user-agent"), null);
		assert.equal(init?.redirect, "manual");
		assert.equal(headers.get("authorization"), "Bearer test-token");
		assert.equal(headers.get("cookie"), null);
		assert.ok(init?.signal);
		return Response.json(raw);
	});
	const result = await fetchRawPayload(
		resolveConfig({ ...env, VPS_RAW_PATH_TEMPLATE: "/raw/{user}/{username}" }),
		"a b",
	);
	assert.equal(result.kind, "ok");
});

test("raw client handles HTTP failures, invalid JSON, empty payloads and network failures", async (t) => {
	for (const [response, kind] of [
		[new Response("", { status: 404 }), "not-found"],
		[new Response("", { status: 403 }), "error"],
		[new Response("", { status: 503 }), "error"],
		[new Response("{"), "error"],
		[Response.json(null), "error"],
		[Response.json({ schema_version: 1, inbounds: [] }), "not-found"],
		[Response.json({ inbounds: [{ users: false }] }), "error"],
	] satisfies [Response, string][]) {
		const mocked = t.mock.method(globalThis, "fetch", async () => response);
		assert.equal((await fetchRawPayload(resolveConfig(env), "alice")).kind, kind);
		mocked.mock.restore();
	}
	t.mock.method(globalThis, "fetch", async () => { throw new Error("network"); });
	assert.equal((await fetchRawPayload(resolveConfig(env), "alice")).kind, "error");
});

test("raw client aborts at configured timeout", async (t) => {
	t.mock.method(globalThis, "fetch", (_url: RequestInfo | URL, init?: RequestInit) =>
		new Promise<Response>((_resolve, reject) => {
			assert.ok(init?.signal);
			init.signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
		}));
	assert.equal((await fetchRawPayload(resolveConfig({ ...env, REQUEST_TIMEOUT_MS: "5" }), "alice")).kind, "error");
});

test("remote template cache hits skip upstream, misses persist TTL using waitUntil", async (t) => {
	const original = Object.getOwnPropertyDescriptor(globalThis, "caches");
	const entries = new Map<string, Response>();
	Object.defineProperty(globalThis, "caches", { configurable: true, value: { default: {
		match: async (request: Request) => entries.get(request.url)?.clone(),
		put: async (request: Request, response: Response) => { entries.set(request.url, response); },
	} } });
	t.after(() => {
		if (original) Object.defineProperty(globalThis, "caches", original);
		else Reflect.deleteProperty(globalThis, "caches");
	});
	const fetched = t.mock.method(globalThis, "fetch", async (_url: RequestInfo | URL, init?: RequestInit) => {
		assert.deepEqual(init?.cf, { cacheTtl: 60, cacheEverything: true });
		return new Response("template", { headers: { "content-type": "text/yaml" } });
	});
	const pending: Promise<void>[] = [];
	assert.equal(await fetchTemplate("https://templates.example/base", 60, { waitUntil: (promise) => { pending.push(promise); } }), "template");
	await Promise.all(pending);
	assert.equal(entries.get("https://templates.example/base")?.headers.get("cache-control"), "public, max-age=60");
	assert.equal(await fetchTemplate("https://templates.example/base", 60), "template");
	assert.equal(fetched.mock.callCount(), 1);
});

test("template failures fall back and cache outages never fail successful downloads", async (t) => {
	const original = Object.getOwnPropertyDescriptor(globalThis, "caches");
	Object.defineProperty(globalThis, "caches", { configurable: true, value: { default: {
		match: async () => { throw new Error("cache unavailable"); },
		put: async () => { throw new Error("quota"); },
	} } });
	t.after(() => {
		if (original) Object.defineProperty(globalThis, "caches", original);
		else Reflect.deleteProperty(globalThis, "caches");
	});
	for (const response of [new Response("", { status: 500 }), new Response("   ")]) {
		const mocked = t.mock.method(globalThis, "fetch", async () => response);
		assert.equal(await fetchTemplate("https://templates.example/base", 60), null);
		mocked.mock.restore();
	}
	const mocked = t.mock.method(globalThis, "fetch", async () => new Response("usable"));
	assert.equal(await fetchTemplate("https://templates.example/base", 60), "usable");
	assert.equal(await fetchTemplate("", 60), null);
	assert.equal(await fetchTemplate("not a url", 60), null);
	mocked.mock.restore();
	t.mock.method(globalThis, "fetch", async () => { throw new Error("offline"); });
	assert.equal(await fetchTemplate("https://templates.example/base", 60), null);
});
