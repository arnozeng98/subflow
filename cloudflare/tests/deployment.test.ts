import assert from "node:assert/strict";
import { test } from "node:test";
import { deploymentConfig } from "../deploy-central.js";
import { readFile } from "node:fs/promises";
import { URL } from "node:url";

test("central deployment binds one persistent database and uses no embedded secrets", () => {
	const config = deploymentConfig("00000000-0000-0000-0000-000000000001", "a".repeat(32), "subflow", "subflow-central");
	assert.equal(config.worker.d1_databases[0]?.binding, "DB");
	assert.equal(config.pages.services[0]?.binding, "CENTRAL");
	assert.equal(config.pages.services[0]?.service, config.worker.name);
	assert.deepEqual(config.worker.triggers.crons, ["*/10 * * * *"]);
	assert.ok(!JSON.stringify(config).includes("ADMIN_TOKEN"));
	assert.throws(() => deploymentConfig("wrong", "a".repeat(32), "subflow", "subflow-central"));
	assert.throws(() => deploymentConfig("00000000-0000-0000-0000-000000000001", "../account", "subflow", "subflow-central"));
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
