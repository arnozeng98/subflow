import assert from "node:assert/strict";
import { test } from "node:test";
import { centralReady, deploymentConfig, pagesOrigin } from "../deploy-central.js";
import { readFile } from "node:fs/promises";
import { URL } from "node:url";

test("central deployment binds one persistent database and uses no embedded secrets", () => {
	const config = deploymentConfig("00000000-0000-0000-0000-000000000001", "a".repeat(32), "subflow", "subflow-central");
	assert.equal(config.worker.d1_databases[0]?.binding, "DB");
	assert.equal(config.pages.services[0]?.binding, "CENTRAL");
	assert.equal(config.pages.services[0]?.service, config.worker.name);
	assert.ok(!("account_id" in config.pages), "Pages takes its account from CLOUDFLARE_ACCOUNT_ID, not its config");
	assert.deepEqual(config.worker.triggers.crons, ["*/10 * * * *"]);
	assert.ok(!JSON.stringify(config).includes("ADMIN_TOKEN"));
	assert.throws(() => deploymentConfig("wrong", "a".repeat(32), "subflow", "subflow-central"));
	assert.throws(() => deploymentConfig("00000000-0000-0000-0000-000000000001", "../account", "subflow", "subflow-central"));
});

test("central deployment uses the assigned Pages subdomain, including collision suffixes", () => {
	assert.equal(pagesOrigin({ name: "subflow", subdomain: "subflow-33v.pages.dev" }), "https://subflow-33v.pages.dev");
	assert.equal(pagesOrigin({ subdomain: "subflow-arnozeng98.pages.dev" }), "https://subflow-arnozeng98.pages.dev");
	for (const value of [{}, null, { subdomain: "example.com" }, { subdomain: "subflow.pages.dev.evil.test" },
		{ subdomain: "subflow.pages.dev/path" }, { subdomain: "https://subflow.pages.dev" }]) {
		assert.throws(() => pagesOrigin(value));
	}
});

test("readiness requires the management page and its assets, not only a healthy API", async t => {
	let broken = "";
	let redirect = false;
	t.mock.method(globalThis, "fetch", async (input: string | URL | Request, init?: RequestInit) => {
		assert.equal(init?.redirect, "error");
		const path = new URL(input instanceof Request ? input.url : input).pathname;
		if (path === "/healthz") return Response.json({ ok: true, version: 1 });
		if (redirect && path === "/manage") throw new TypeError("unexpected redirect");
		const mime: Record<string, string> = { "/manage": "text/html", "/admin.js": "text/javascript", "/admin.css": "text/css" };
		return new Response("asset", { status: path === broken ? 404 : 200, headers: { "content-type": mime[path] || "text/plain" } });
	});
	assert.equal(await centralReady("https://subflow.pages.dev"), true);
	for (broken of ["/manage", "/admin.js", "/admin.css"]) {
		assert.equal(await centralReady("https://subflow.pages.dev"), false);
	}
	broken = "";
	redirect = true;
	await assert.rejects(centralReady("https://subflow.pages.dev"), /unexpected redirect/);
});

test("admin form controls cannot shadow native form reset and username pattern supports HTML v mode", async () => {
	const html = await readFile(new URL("../admin/index.html", import.meta.url), "utf8");
	assert.doesNotMatch(html, /name="(?:reset|submit|action|elements)"/);
	const pattern = /name="username"[^>]*pattern="([^"]+)"/.exec(html)?.[1];
	assert.ok(pattern);
	const regex = new RegExp(`^(?:${pattern})$`, "v");
	assert.ok(regex.test("ricy-test_1"));
	assert.ok(!regex.test("bad/name"));
});
