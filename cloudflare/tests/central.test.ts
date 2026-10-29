import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { URL as FileURL } from "node:url";
import { test } from "node:test";
import { build } from "esbuild";
import { convertV4MiniflareOptions, Miniflare, Response as LocalResponse } from "miniflare";
import { parseTraffic, vendorSummary } from "../central/bandwagon.js";
import { nextReset } from "../central/admin.js";
import { safePayload } from "../central/sync.js";
import { decrypt, encrypt, hash } from "../central/security.js";
import { isRecord } from "../functions/_lib/types.js";
import { raw } from "./fixture.js";

test("vendor accounting uses documented multiplier on both counters and rejects unknown data", () => {
	assert.deepEqual(parseTraffic({ error: 0, plan_monthly_data: "100", data_counter: "20", monthly_data_multiplier: 2, data_next_reset: 2000000000 }),
		{ total: 200, used: 40, multiplier: 2, reset: 2000000000 });
	assert.throws(() => parseTraffic({ error: 0, plan_monthly_data: 100, data_counter: 20 }));
	assert.throws(() => parseTraffic({ error: 1 }));
	const base = { vendor_total: 100, vendor_used: 120, vendor_updated: 1000, vendor_reset: 9999, vendor_error: null };
	assert.deepEqual(vendorSummary([base, { ...base, vendor_used: 20 }], 1100), { complete: true, used: 140, remaining: 80, total: 220 });
	assert.equal(vendorSummary([base], 3000).complete, false);
	assert.equal(vendorSummary([{ ...base, vendor_error: "failed" }], 1100).complete, false);
	assert.equal(vendorSummary([], 1100).complete, false);
});

test("credential encryption is authenticated and bound to server identity", async () => {
	const key = "b".repeat(64), secret = await encrypt("test-vendor-key", key, "one");
	assert.ok(!secret.includes("test-vendor-key"));
	assert.equal(await decrypt(secret, key, "one"), "test-vendor-key");
	await assert.rejects(decrypt(secret, key, "two"));
	await assert.rejects(decrypt(secret, "c".repeat(64), "one"));
});

test("safe projection rejects cross-user credentials and monthly reset uses Shanghai midnight", () => {
	const value = safePayload({ ...raw, inbounds: [...raw.inbounds, { type: "trojan", users: [{ name: "n@bob", password: "other-secret" }] }] }, "alice");
	assert.ok(!JSON.stringify(value).includes("other-secret"));
	assert.equal(nextReset(1, Date.parse("2026-10-15T00:00:00Z") / 1000), Date.parse("2026-10-31T16:00:00Z") / 1000);
	assert.equal(nextReset(0, 123), 0);
	assert.equal(nextReset(31, Date.parse("2027-02-01T00:00:00Z") / 1000), Date.parse("2027-02-27T16:00:00Z") / 1000);
});

test("central HTTP and real D1 transactions: enrollment, shared quota, retries, isolation and subscriptions", async t => {
	const output = await build({ entryPoints: ["cloudflare/central/worker.ts"], bundle: true, format: "esm", write: false, platform: "browser" });
	const script = output.outputFiles[0]?.text;
	assert.ok(script);
	const adminToken = "a".repeat(64);
	let vendorFails = false;
	let vendorCalls = 0;
	const vendorRequests: { url: string; method: string; hasKey: boolean; veid: string | null }[] = [];
	const mf = new Miniflare(convertV4MiniflareOptions({
		modules: true, script, compatibilityDate: "2026-06-08", d1Databases: ["DB"],
		bindings: { ADMIN_TOKEN: adminToken, CREDENTIAL_KEY: "b".repeat(64) },
		outboundService: async request => {
			const parameters = new URLSearchParams(await request.text());
			vendorRequests.push({ url: request.url, method: request.method, hasKey: parameters.has("api_key"), veid: parameters.get("veid") });
			vendorCalls++;
			return new LocalResponse(JSON.stringify(vendorFails ? { error: 1, message: "super-secret-provider-key" } : {
				error: 0, plan_monthly_data: 1000, data_counter: 250, monthly_data_multiplier: 2,
				data_next_reset: Math.floor(Date.now() / 1000) + 86400,
			}), { headers: { "content-type": "application/json" } });
		},
	}));
	t.after(() => mf.dispose());
	const db = await mf.getD1Database("DB");
	const migration = await readFile(new FileURL("../central/migrations/0001_central.sql", import.meta.url), "utf8");
	const statements = migration.match(/CREATE TRIGGER[\s\S]*?END;|(?:CREATE|INSERT)[^;]+;/g);
	assert.ok(statements);
	await db.batch(statements.map(sql => db.prepare(sql)));
	async function request(path: string, method = "GET", value?: unknown, headers: Record<string, string> = {}) {
		const response = await mf.dispatchFetch(`https://central.test${path}`, {
			method, headers: { "content-type": "application/json", ...headers },
			...(value === undefined ? {} : { body: JSON.stringify(value) }),
		});
		return response;
	}
	const adminHeaders = { authorization: `Bearer ${adminToken}` };
	async function admin(path: string, method = "GET", value?: unknown) {
		const response = await request(`/admin/${path}`, method, value, adminHeaders);
		const result: unknown = await response.json();
		assert.ok(isRecord(result));
		assert.ok(response.ok, `${JSON.stringify(result)}; provider requests: ${JSON.stringify(vendorRequests)}`);
		return result;
	}
	assert.equal((await request("/admin/overview")).status, 401);
	assert.equal((await request("/admin/overview", "GET", undefined, { ...adminHeaders, origin: "https://evil.test" })).status, 403);
	await admin("overview");
	const a = await admin("servers", "POST", { name: "A" }), b = await admin("servers", "POST", { name: "B" });
	const aToken = "c".repeat(64), bToken = "d".repeat(64);
	for (const [server, agentToken] of [[a, aToken], [b, bToken]] as const) {
		const value = { version: 1, token: server.enrollment_token, agent_token: agentToken, instance_id: `instance-${server.id}` };
		assert.equal((await request("/agent/enroll", "POST", value)).status, 200);
		assert.equal((await request("/agent/enroll", "POST", value)).status, 200);
		assert.equal((await request("/agent/enroll", "POST", { ...value, agent_token: "e".repeat(64) })).status, 409);
	}
	const user = await admin("users", "POST", { username: "alice", enabled: true, quota_bytes: 100, expires_at: 0, reset_day: 0,
		permissions: [{ server_id: a.id, nodes: ["*"] }, { server_id: b.id, nodes: ["*"] }] });
	const agentHeaders = (id: unknown, token: string) => ({ authorization: `Bearer ${token}`, "x-subflow-server": String(id) });
	const sync = { version: 1, sequence: 1, applied_revision: 0, reports: [], payloads: {}, inventory: [{ tag: "reality-in", type: "vless" }] };
	const firstResponses = await Promise.all([
		request("/agent/sync", "POST", sync, agentHeaders(a.id, aToken)),
		request("/agent/sync", "POST", sync, agentHeaders(b.id, bToken)),
	]);
	const responses: Record<string, unknown>[] = [];
	for (const response of firstResponses) {
		const value: unknown = await response.json(); assert.ok(isRecord(value)); assert.equal(response.status, 200, JSON.stringify(value)); responses.push(value);
	}
	const grants = await db.prepare("SELECT SUM(grant_bytes) AS n FROM usage WHERE username='alice'").first<{ n: number }>();
	assert.equal(grants?.n, 100, "simultaneous nodes must never each receive a full global quota");
	const retry = await request("/agent/sync", "POST", sync, agentHeaders(a.id, aToken));
	assert.deepEqual(await retry.json(), responses[0]);
	assert.equal((await request("/agent/sync", "POST", { ...sync, applied_revision: 1 }, agentHeaders(a.id, aToken))).status, 409);
	assert.equal((await request("/agent/sync", "POST", sync, agentHeaders(a.id, bToken))).status, 401);
	const next = { ...sync, sequence: 2, applied_revision: responses[0]?.revision, reports: [{ username: "alice", period: 1, up: 10, down: 20 }],
		payloads: { alice: raw, admin: { ...raw, username: "admin", inbounds: raw.inbounds.map(inbound => ({
			...inbound, users: inbound.users?.map(user => ({ ...user, name: user.name?.replace("@alice", "") })),
		})) } } };
	const accepted = await request("/agent/sync", "POST", next, agentHeaders(a.id, aToken));
	assert.equal(accepted.status, 200, await accepted.text());
	const usage = await db.prepare("SELECT up,down FROM usage WHERE server_id=? AND username='alice'").bind(a.id).first();
	assert.deepEqual(usage, { up: 10, down: 20 });
	assert.equal((await request("/agent/sync", "POST", next, agentHeaders(a.id, aToken))).status, 200);
	const aggregate = await db.prepare("SELECT SUM(up+down) AS n FROM usage WHERE username='alice'").first<{ n: number }>();
	assert.equal(aggregate?.n, 30);
	const regression = await request("/agent/sync", "POST", { ...next, sequence: 3, reports: [{ username: "alice", period: 1, up: 9, down: 20 }] }, agentHeaders(a.id, aToken));
	assert.equal(regression.status, 409);
	const stored = await db.prepare("SELECT last_sequence FROM servers WHERE id=?").bind(a.id).first<{ last_sequence: number }>();
	assert.equal(stored?.last_sequence, 2, "counter failure must roll back sequence");
	const adminUsage = await request("/agent/sync", "POST", { ...next, sequence: 3, reports: [{ username: "admin", period: 1, up: 0, down: 0 }] }, agentHeaders(a.id, aToken));
	assert.equal(adminUsage.status, 400);
	const subscription = await request(`${user.subscription_path}?format=universal`);
	assert.equal(subscription.status, 200, await subscription.clone().text());
	assert.equal(subscription.headers.get("subscription-userinfo"), "upload=10; download=20; total=100");
	assert.equal(subscription.headers.get("cache-control"), "no-store");
	assert.equal((await request("/alice")).status, 404);
	const oldPath = String(user.subscription_path);
	const rotated = await admin("users/alice/token", "POST", {});
	assert.equal((await request(oldPath)).status, 404);
	assert.equal((await request(String(rotated.subscription_path))).status, 200);
	await admin("servers/" + a.id + "/vendor", "PUT", { veid: "123", api_key: "super-secret-provider-key" });
	const overview = await admin("overview");
	assert.ok(!JSON.stringify(overview).includes("super-secret-provider-key"));
	assert.ok(!JSON.stringify(overview).includes("agent_hash"));
	assert.ok(!JSON.stringify(overview).includes("token_hash"));
	const encrypted = await db.prepare("SELECT vendor_secret FROM servers WHERE id=?").bind(a.id).first<{ vendor_secret: string }>();
	assert.ok(encrypted?.vendor_secret && !encrypted.vendor_secret.includes("super-secret-provider-key"));
	const adminSub = await admin("users/admin/token", "POST", {});
	assert.equal((await request(String(adminSub.subscription_path))).status, 503, "missing vendor data is not a zero balance");
	await admin("servers/" + b.id + "/vendor", "PUT", { veid: "456", api_key: "second-test-provider-key" });
	await admin("servers/" + a.id + "/collect", "POST", {});
	await admin("servers/" + b.id + "/collect", "POST", {});
	assert.equal(vendorCalls, 2);
	assert.deepEqual(vendorRequests, [
		{ url: "https://api.64clouds.com/v1/getServiceInfo", method: "POST", hasKey: true, veid: "123" },
		{ url: "https://api.64clouds.com/v1/getServiceInfo", method: "POST", hasKey: true, veid: "456" },
	]);
	const completeAdmin = await request(String(adminSub.subscription_path));
	assert.equal(completeAdmin.status, 200);
	assert.equal(completeAdmin.headers.get("subscription-userinfo"), "upload=0; download=1000; total=4000");
	const forbiddenCount = await db.prepare("SELECT COUNT(*) AS n FROM usage WHERE username='admin'").first<{ n: number }>();
	assert.equal(forbiddenCount?.n, 0);
	vendorFails = true;
	await db.prepare("UPDATE servers SET vendor_updated=vendor_updated-61 WHERE id=?").bind(a.id).run();
	const failedCollection = await request(`/admin/servers/${a.id}/collect`, "POST", {}, adminHeaders);
	assert.equal(failedCollection.status, 502);
	assert.ok(!(await failedCollection.text()).includes("super-secret"));
	assert.equal((await request(String(adminSub.subscription_path))).status, 503);
	const lastTraffic = await db.prepare("SELECT vendor_used FROM servers WHERE id=?").bind(a.id).first<{ vendor_used: number }>();
	assert.equal(lastTraffic?.vendor_used, 500, "failure preserves last known traffic");
	assert.equal((await request(String(rotated.subscription_path))).status, 200, "ordinary subscription independent of vendor outage");
	await admin("users/alice/reset", "POST", {});
	const afterReset = await db.prepare("SELECT period FROM users WHERE username='alice'").first<{ period: number }>();
	assert.equal(afterReset?.period, 2);
	assert.equal((await request(String(rotated.subscription_path))).status, 503, "old-revision nodes cannot masquerade as applied new policy");
	const rolled = { ...next, sequence: 3, reports: [{ username: "alice", period: 1, up: 15, down: 25 }] };
	const raced = await Promise.all([
		request("/agent/sync", "POST", rolled, agentHeaders(a.id, aToken)),
		request("/agent/sync", "POST", rolled, agentHeaders(a.id, aToken)),
	]);
	assert.ok(raced.some(r => r.status === 200));
	assert.ok(raced.every(r => r.status === 200 || r.status === 409));
	const retryRollover = await request("/agent/sync", "POST", rolled, agentHeaders(a.id, aToken));
	assert.equal(retryRollover.status, 200);
	const oldPeriod = await db.prepare("SELECT up+down AS n FROM usage WHERE username='alice' AND server_id=? AND period=1")
		.bind(a.id).first<{ n: number }>();
	assert.equal(oldPeriod?.n, 40, "late old-period usage remains in its original ledger");
	const newPeriod = await db.prepare("SELECT up+down AS n FROM usage WHERE username='alice' AND server_id=? AND period=2")
		.bind(a.id).first<{ n: number }>();
	assert.equal(newPeriod?.n, 0, "late reports cannot consume a new period twice");
	await db.prepare("UPDATE control SET credential_key_hash='original' WHERE id=1").run();
	await assert.rejects(db.prepare("UPDATE control SET credential_key_hash='changed' WHERE id=1").run(), /credential encryption key changed/);
	await admin("servers/" + b.id, "DELETE");
	const retired = await db.prepare("SELECT enabled,retired,vendor_secret FROM servers WHERE id=?").bind(b.id).first();
	assert.deepEqual(retired, { enabled: 0, retired: 1, vendor_secret: null });
	const retained = await db.prepare("SELECT COUNT(*) AS n FROM usage WHERE server_id=?").bind(b.id).first<{ n: number }>();
	assert.ok(retained && retained.n > 0, "retirement must not discard reservations or usage history");
	assert.ok((await hash(adminToken)).length === 64);
});
