import assert from "node:assert/strict";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { test } from "node:test";
import { URL as FileURL } from "node:url";
import { onRequestGet } from "../functions/[user].js";
import { resolveConfig, hasUpstream } from "../functions/_lib/config.js";
import { FORMAT, PROTOCOL } from "../functions/_lib/constants.js";
import { buildNodes, detectProtocol } from "../functions/_lib/protocol.js";
import { buildLink, base64NoWrap } from "../functions/_lib/links.js";
import { negotiateFormat, normalizeFormat } from "../functions/_lib/format.js";
import { buildSubscriptionUserinfo } from "../functions/_lib/userinfo.js";
import { generate } from "../functions/_lib/templates/index.js";
import { generateSingbox } from "../functions/_lib/templates/singbox.js";
import { generateClash } from "../functions/_lib/templates/clash.js";
import { isRawPayload, isJsonObject } from "../functions/_lib/types.js";
import type { Env, GatewayContext } from "../functions/_lib/types.js";
import { raw, env } from "./fixture.js";

const config = resolveConfig(env);
const nodes = buildNodes(raw);

test("all six output formats match reviewed fixtures", async (t) => {
	for (const format of Object.values(FORMAT)) {
		await t.test(format, async () => {
			const result = await generate(format, nodes, config);
			const path = new FileURL(`./fixtures/${format}.txt`, import.meta.url);
			if (process.env.UPDATE_FIXTURES === "1") {
				await mkdir(new FileURL("./fixtures", import.meta.url), { recursive: true });
				await writeFile(path, result.body);
			}
			assert.equal(result.body, await readFile(path, "utf8"));
			assert.doesNotMatch(result.body, /@alice/);
			if (format === "singbox") {
				const document: unknown = JSON.parse(result.body);
				assert.ok(isJsonObject(document));
				assert.ok(Array.isArray(document.outbounds));
				assert.equal(document.outbounds.length, 12);
			}
		});
	}
});

test("normalization covers every protocol and hides usernames", () => {
	assert.equal(nodes.length, 7);
	assert.deepEqual(nodes.map((node) => node.protocol), [
		"vless-reality", "shadowsocks", "vmess-ws", "vless-ws", "tuic", "trojan", "anytls",
	]);
	assert.equal(nodes.find((node) => node.protocol === "shadowsocks")?.password, "SERVERPW:USERPW");
	assert.equal(nodes.find((node) => node.protocol === "vmess-ws")?.wsPathWithEarlyData, "/wspath?ed=2048");
	assert.equal(nodes.find((node) => node.protocol === "vless-ws")?.wsPathWithEarlyData, "/vless?ed=1024");
	assert.equal(nodes.find((node) => node.protocol === "vmess-ws")?.wsHost, "vm.example.com");
	assert.equal(nodes[0]?.realityPublicKey, "PBKEY123");
	assert.equal(nodes[0]?.name, "東京");
	assert.ok(nodes.every((node) => !node.name.includes("@")));
	assert.equal(detectProtocol({ type: "socks" }), PROTOCOL.SOCKS);
	assert.equal(detectProtocol({ type: "http" }), "");
	assert.deepEqual(buildNodes({ inbounds: [{ type: "http" }, { type: "trojan", users: [{}] }] }), []);
	const fallback = buildNodes({ inbounds: [{ type: "shadowsocks", users: [{ username: "fallback" }] }] })[0];
	assert.ok(fallback);
	assert.equal(fallback.method, "2022-blake3-aes-128-gcm");
	assert.equal(fallback.sni, "www.icloud.com");
	assert.equal(fallback.port, 0);
	assert.equal(buildLink({ ...fallback, protocol: "socks" }), "");
});

test("link generation retains UTF-8, encoded credentials and WS settings", () => {
	assert.equal(Buffer.from(base64NoWrap("東京"), "base64").toString("utf8"), "東京");
	const trojan = nodes.find((node) => node.protocol === "trojan");
	const vmess = nodes.find((node) => node.protocol === "vmess-ws");
	assert.ok(trojan && vmess);
	assert.match(buildLink(trojan), /test%2Bpassword/);
	const payload: unknown = JSON.parse(Buffer.from(buildLink(vmess).slice(8), "base64").toString());
	assert.ok(isJsonObject(payload));
	assert.equal(payload.port, "443");
	assert.equal(payload.path, "/wspath?ed=2048");
});

test("format precedence, aliases, config defaults and env overrides", () => {
	assert.equal(negotiateFormat("qx", "Clash", "universal"), "quantumultx");
	assert.equal(negotiateFormat("invalid", "Stash", "surge"), "clash");
	assert.equal(negotiateFormat(null, "sing-box", "surge"), "singbox");
	assert.equal(negotiateFormat(null, "Quantumult%20X", "surge"), "quantumultx");
	assert.equal(negotiateFormat(null, "Shadowrocket", "surge"), "shadowrocket");
	assert.equal(negotiateFormat(null, "Surge", "universal"), "surge");
	assert.equal(negotiateFormat(null, "curl", "universal"), "universal");
	assert.equal(normalizeFormat(" CLASH.META "), "clash");
	assert.equal(normalizeFormat(null), "");
	assert.equal(config.apiBaseUrl, "https://vps.example.com");
	assert.equal(hasUpstream(resolveConfig({})), false);
	const custom = resolveConfig({ ...env, REQUEST_TIMEOUT_MS: "-1", TEMPLATE_CACHE_TTL_SECONDS: "60", SUBFLOW_PROFILE_NAME: "Custom", SUBFLOW_CLASH_RULES_BASE: "https://rules.example/" });
	assert.equal(custom.requestTimeoutMs, 8000);
	assert.equal(custom.responseCacheControl, "no-store");
	assert.equal(custom.ruleSources.clashRulesBase, "https://rules.example");
});

test("usage headers preserve actual bytes and support seconds, milliseconds and dates", () => {
	assert.equal(buildSubscriptionUserinfo(), "");
	assert.equal(buildSubscriptionUserinfo({ quota_gb: 0 }), "");
	assert.equal(buildSubscriptionUserinfo(raw.usage), "upload=1000; download=2000; total=107374182400; expire=1893456000");
	for (const expire_at of ["1893456000000", "2030-01-01T00:00:00Z"]) {
		assert.equal(buildSubscriptionUserinfo({ expire_at }), "upload=0; download=0; expire=1893456000");
	}
	assert.equal(buildSubscriptionUserinfo({ quota_gb: "1", used_up_bytes: -5, used_down_bytes: "bad", expire_at: "invalid" }), "upload=0; download=0; total=1073741824");
});

test("custom templates preserve injection and reject invalid JSON roots", () => {
	const clash = generateClash(nodes, config, "#SUBFLOW_PROXIES\n#SUBFLOW_GROUPS\n#SUBFLOW_PROVIDERS\n#SUBFLOW_RULES");
	assert.match(clash.body, /^proxies:/);
	assert.doesNotMatch(clash.body, /#SUBFLOW_/);
	assert.match(generateClash(nodes, config, "invalid").body, /mixed-port: 7892/);
	const singbox: unknown = JSON.parse(generateSingbox(nodes, config, '{"log":{"level":"debug"},"outbounds":[]}').body);
	assert.ok(isJsonObject(singbox));
	assert.deepEqual(singbox.log, { level: "debug" });
	assert.ok(Array.isArray(singbox.outbounds) && singbox.outbounds.length > 0);
	for (const invalid of ["null", "[]", '"text"', "{"]) {
		assert.equal(generateSingbox(nodes, config, invalid).body, generateSingbox(nodes, config).body);
	}
});

test("upstream payload guards reject malformed nested fields", () => {
	assert.ok(isRawPayload(raw));
	for (const invalid of [null, {}, { inbounds: [null] }, { inbounds: [{ users: "bad" }] }, { inbounds: [], usage: { quota_gb: {} } }]) {
		assert.equal(isRawPayload(invalid), false);
	}
});

function context(user: string | string[], environment: Env = env, format = "clash"): GatewayContext {
	return {
		request: new Request(`https://sub.example/alice?format=${format}`),
		env: environment,
		params: { user },
		functionPath: "/[user]",
		data: {},
		next: async () => new Response("native-not-found", { status: 404 }),
		waitUntil: () => {},
		passThroughOnException: () => {},
	};
}

test("Pages gateway preserves native 404 and configuration errors", async (t) => {
	t.mock.method(globalThis, "fetch", async () => { throw new Error("must not fetch"); });
	for (const user of ["", "../secret", "bad/name", "a".repeat(65), ["alice"]]) {
		const response = await onRequestGet(context(user));
		assert.equal(response.status, 404);
		assert.equal(await response.text(), "native-not-found");
	}
	const response = await onRequestGet(context("alice", {}));
	assert.equal(response.status, 500);
	assert.equal(response.headers.get("cache-control"), "no-store");
});

test("Pages gateway succeeds in all formats with safe headers and upstream auth", async (t) => {
	t.mock.method(globalThis, "fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
		assert.equal(String(input), "https://vps.example.com/internal/raw/alice");
		assert.equal(new Headers(init?.headers).get("authorization"), "Bearer test-token");
		return Response.json(raw);
	});
	for (const format of Object.values(FORMAT)) {
		const response = await onRequestGet(context("alice", env, format));
		assert.equal(response.status, 200);
		assert.equal(response.headers.get("x-content-type-options"), "nosniff");
		assert.equal(response.headers.get("profile-update-interval"), "24");
		assert.equal(response.headers.get("subscription-userinfo"), buildSubscriptionUserinfo(raw.usage));
		assert.equal(response.headers.get("cache-control"), config.responseCacheControl);
		assert.equal(await response.text(), (await generate(format, nodes, config)).body);
	}
});

test("Pages gateway distinguishes missing users from failed upstreams", async (t) => {
	for (const [status, payload, expected] of [
		[404, {}, 404], [500, {}, 502], [200, { schema_version: 1, inbounds: [] }, 404],
		[200, { schema_version: 1, inbounds: [{ type: "http" }] }, 404], [200, { schema_version: 1, inbounds: [null] }, 502],
		[200, { inbounds: [] }, 502],
	] satisfies [number, object, number][]) {
		const mocked = t.mock.method(globalThis, "fetch", async () => Response.json(payload, { status }));
		const response = await onRequestGet(context("alice"));
		assert.equal(response.status, expected);
		if (expected === 502) assert.equal(response.headers.get("cache-control"), "no-store");
		mocked.mock.restore();
	}
});

test("shared Go API contract fixture is accepted and rendered in every format", async (t) => {
	const payload: unknown = JSON.parse(await readFile(
		new FileURL("../../contracts/fixtures/raw-alice.json", import.meta.url), "utf8",
	));
	assert.ok(isRawPayload(payload));
	const contractNodes = buildNodes(payload);
	assert.deepEqual(contractNodes.map((node) => node.protocol), [
		"vless-reality", "shadowsocks", "vmess-ws", "tuic",
	]);
	assert.deepEqual(contractNodes.map((node) => node.name), ["tokyo", "osaka", "cdn", "fast"]);
	assert.equal(contractNodes[0]?.realityPublicKey, "PBKEY123");
	assert.equal(contractNodes[1]?.password, "MDEyMzQ1Njc4OWFiY2RlZg==:ZmVkY2JhOTg3NjU0MzIxMA==");
	assert.equal(contractNodes[2]?.wsHost, "vm.example.com");
	const userinfo = "upload=1000000000; download=2000000000; total=107374182400; expire=1798761600";
	assert.equal(buildSubscriptionUserinfo(payload.usage), userinfo);
	t.mock.method(globalThis, "fetch", async () => Response.json(payload));
	for (const format of Object.values(FORMAT)) {
		const response = await onRequestGet(context("alice", env, format));
		const expected = await generate(format, contractNodes, config);
		assert.equal(response.status, 200);
		assert.equal(response.headers.get("content-type"), expected.contentType);
		assert.equal(response.headers.get("subscription-userinfo"), userinfo);
		assert.equal(await response.text(), expected.body);
	}
});
