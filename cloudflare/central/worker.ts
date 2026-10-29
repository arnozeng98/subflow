import { admin, resetDue } from "./admin.js";
import { collectServer } from "./bandwagon.js";
import { bearer, matches } from "./security.js";
import { enroll, synchronize } from "./sync.js";
import { subscription } from "./subscription.js";
import { HTTPError, json } from "./types.js";
import type { CentralEnv, ServerRow } from "./types.js";

export async function scheduled(env: CentralEnv, now: number): Promise<void> {
	await resetDue(env, now);
	const servers = await env.DB.prepare("SELECT * FROM servers WHERE retired=0 AND vendor_secret IS NOT NULL ORDER BY id").all<ServerRow>();
	for (const server of servers.results) await collectServer(env, server, now);
	await env.DB.prepare("DELETE FROM audit WHERE created_at<?").bind(now - 90 * 86400).run();
}

export default {
	async fetch(request: Request, env: CentralEnv): Promise<Response> {
		const now = Math.floor(Date.now() / 1000), path = new URL(request.url).pathname;
		try {
			if (path === "/healthz" && request.method === "GET") {
				const db = await env.DB.prepare("SELECT revision FROM control WHERE id=1").first();
				if (!db) throw new Error("database not initialized");
				return json({ ok: true, version: 1 });
			}
			if (path.startsWith("/admin/")) {
				if (!/^[A-Za-z0-9_-]{32,256}$/.test(env.ADMIN_TOKEN || "")) throw new Error("ADMIN_TOKEN is not configured");
				if (!(await matches(bearer(request), env.ADMIN_TOKEN))) throw new HTTPError(401, "invalid administrator credential");
				const origin = request.headers.get("origin");
				if (origin && origin !== new URL(request.url).origin) throw new HTTPError(403, "cross-origin admin request denied");
				return await admin(request, env, path.slice(7).split("/"), now);
			}
			if (path === "/agent/enroll" && request.method === "POST") return await enroll(request, env, now);
			if (path === "/agent/sync" && request.method === "POST") return await synchronize(request, env, now);
			const match = /^\/s\/([a-f0-9]{64})$/.exec(path);
			if (match?.[1] && request.method === "GET") return await subscription(request, env, match[1], now);
			throw new HTTPError(404, "not found");
		} catch (error) {
			if (error instanceof HTTPError) return json({ error: error.message }, error.status);
			console.error("Central request failed", { route: path.startsWith("/s/") ? "/s/[redacted]" : path.split("/").slice(0, 2).join("/"),
				errorType: error instanceof Error ? error.name : "unknown" });
			return json({ error: "central service unavailable" }, 503);
		}
	},
	async scheduled(_event: ScheduledController, env: CentralEnv): Promise<void> {
		await scheduled(env, Math.floor(Date.now() / 1000));
	},
} satisfies ExportedHandler<CentralEnv>;
