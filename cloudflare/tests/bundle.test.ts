import assert from "node:assert/strict";
import { test } from "node:test";
import { build } from "esbuild";
import { fileURLToPath, URL } from "node:url";
import { join } from "node:path";
import worker from "../worker.js";
import type { WorkerEnv } from "../worker.js";
import { env, raw } from "./fixture.js";

test("Pages entry bundles into a self-contained browser ESM worker", async () => {
	const root = fileURLToPath(new URL("../..", import.meta.url));
	const result = await build({
		absWorkingDir: root,
		entryPoints: [join("cloudflare", "worker.ts")],
		bundle: true,
		write: false,
		format: "esm",
		platform: "browser",
		target: "es2022",
		metafile: true,
	});
	assert.equal(result.outputFiles.length, 1);
	const output = result.outputFiles[0];
	assert.ok(output);
	assert.match(output.text, /export\s*\{/);
	assert.doesNotMatch(output.text, /node:|require\(/);
	assert.ok(Object.values(result.metafile.outputs).every((entry) => entry.imports.length === 0));
});

const ctx: Pick<ExecutionContext, "waitUntil" | "passThroughOnException"> = {
	waitUntil: () => {},
	passThroughOnException: () => {},
};

test("advanced-mode worker preserves one-segment GET routing and native missing routes", async (t) => {
	const upstream = t.mock.method(globalThis, "fetch", async () => Response.json(raw));
	for (const path of ["/", "/alice/extra", "/bad%2Fname", "/%E0%A4%A"]) {
		assert.equal((await worker.fetch(new Request(`https://sub.example${path}`), env, ctx)).status, 404);
	}
	assert.equal((await worker.fetch(new Request("https://sub.example/alice", { method: "POST" }), env, ctx)).status, 404);
	assert.equal(upstream.mock.callCount(), 0);
	assert.equal((await worker.fetch(new Request("https://sub.example/alice/"), env, ctx)).status, 200);
	assert.equal((await worker.fetch(new Request("https://sub.example/alice"), {}, ctx)).status, 500);
});

test("central Pages routing forwards agents and subscriptions, disables username routes and protects UI assets", async () => {
	const calls: string[] = [];
	const central: Pick<Fetcher, "fetch"> = { fetch: async (request: RequestInfo | URL) => {
		const url = typeof request === "string" ? request : request instanceof Request ? request.url : request.toString();
		calls.push(url); return Response.json({ ok: true });
	} };
	const assets: Pick<Fetcher, "fetch"> = { fetch: async () => new Response("<html>test UI</html>", { headers: { "content-type": "text/html" } }) };
	const environment: WorkerEnv = { CENTRAL: central, ASSETS: assets };
	for (const path of ["/agent/enroll", "/agent/sync", "/admin/overview", "/s/" + "a".repeat(64)]) {
		assert.equal((await worker.fetch(new Request("https://sub.example" + path), environment, ctx)).status, 200);
	}
	assert.equal(calls.length, 4);
	assert.equal((await worker.fetch(new Request("https://sub.example/alice"), environment, ctx)).status, 404);
	const ui = await worker.fetch(new Request("https://sub.example/manage"), environment, ctx);
	assert.equal(ui.status, 200);
	assert.equal(ui.headers.get("cache-control"), "no-store");
	assert.match(ui.headers.get("content-security-policy") || "", /frame-ancestors 'none'/);
	assert.equal(await ui.text(), "<html>test UI</html>");
});
