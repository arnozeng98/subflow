import { isRecord } from "../functions/_lib/types.js";
import { collectServer, vendorSummary } from "./bandwagon.js";
import { body, encrypt, hash, randomToken } from "./security.js";
import { HTTPError, integer, json, text, username } from "./types.js";
import type { CentralEnv, ServerRow } from "./types.js";

export function nextReset(day: number, now: number): number {
	if (!day) return 0;
	const local = new Date((now + 8 * 3600) * 1000);
	const inMonth = (month: number) => {
		const last = new Date(Date.UTC(local.getUTCFullYear(), month + 1, 0)).getUTCDate();
		return Date.UTC(local.getUTCFullYear(), month, Math.min(day, last)) / 1000 - 8 * 3600;
	};
	let timestamp = inMonth(local.getUTCMonth());
	if (timestamp <= now) timestamp = inMonth(local.getUTCMonth() + 1);
	return timestamp;
}

function audit(env: CentralEnv, action: string, target: string, now: number): D1PreparedStatement {
	return env.DB.prepare("INSERT INTO audit(action,target,created_at) VALUES(?,?,?)").bind(action, target, now);
}

function revision(env: CentralEnv): D1PreparedStatement {
	return env.DB.prepare("UPDATE control SET revision=revision+1 WHERE id=1");
}

export async function resetDue(env: CentralEnv, now: number): Promise<void> {
	const due = await env.DB.prepare("SELECT username,reset_day,next_reset FROM users WHERE next_reset>0 AND next_reset<=? AND username<>'admin'")
		.bind(now).all<{ username: string; reset_day: number; next_reset: number }>();
	for (const user of due.results) {
		await env.DB.batch([
			revision(env),
			env.DB.prepare(`UPDATE users SET period=period+1,next_reset=?,revision=(SELECT revision FROM control WHERE id=1)
				WHERE username=? AND next_reset=?`).bind(nextReset(user.reset_day, now), user.username, user.next_reset),
		]);
	}
}

export async function admin(request: Request, env: CentralEnv, path: string[], now: number): Promise<Response> {
	await env.DB.prepare(`INSERT OR IGNORE INTO users(username,enabled,quota_bytes,token_hash,created_at)
		VALUES('admin',1,0,?,?)`).bind(await hash(randomToken()), now).run();
	if (request.method === "GET" && path.join("/") === "overview") {
		const servers = await env.DB.prepare(`SELECT id,name,enabled,last_seen,applied_revision,inventory,veid,
			vendor_total,vendor_used,vendor_reset,vendor_multiplier,vendor_updated,vendor_error,
			agent_hash IS NOT NULL AS enrolled,vendor_secret IS NOT NULL AS vendor_configured FROM servers WHERE retired=0 ORDER BY name`)
			.all<ServerRow & { inventory: string }>();
		const users = await env.DB.prepare(`SELECT u.username,u.enabled,u.quota_bytes,u.period,u.expires_at,u.reset_day,u.next_reset,u.revision,
			COALESCE(SUM(g.up),0) AS up,COALESCE(SUM(g.down),0) AS down,
			COALESCE(SUM(MAX(g.grant_bytes,g.up+g.down)),0) AS reserved
			FROM users u LEFT JOIN usage g ON g.username=u.username AND g.period=u.period GROUP BY u.username ORDER BY u.username`).all();
		const permissions = await env.DB.prepare("SELECT * FROM permissions ORDER BY username,server_id").all();
		const logs = await env.DB.prepare("SELECT action,target,created_at FROM audit ORDER BY id DESC LIMIT 50").all();
		const control = await env.DB.prepare("SELECT revision FROM control WHERE id=1").first<{ revision: number }>();
		return json({ now, revision: control?.revision, summary: vendorSummary(servers.results, now),
			servers: servers.results, users: users.results, permissions: permissions.results, audit: logs.results });
	}
	if (request.method === "POST" && path.join("/") === "servers") {
		const value = await body(request);
		const name = text(value.name, "server name", 80), id = crypto.randomUUID(), token = randomToken();
		const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM servers WHERE retired=0").first<{ n: number }>();
		if ((count?.n || 0) >= 50) throw new HTTPError(409, "this deployment supports at most 50 registered servers");
		await env.DB.batch([
			revision(env),
			env.DB.prepare(`INSERT INTO servers(id,name,enrollment_hash,enrollment_expires) VALUES(?,?,?,?)`)
				.bind(id, name, await hash(token), now + 3600),
			env.DB.prepare("INSERT INTO permissions(username,server_id) VALUES('admin',?)").bind(id),
			audit(env, "server.create", id, now),
		]);
		return json({ id, enrollment_token: token, enrollment_expires: now + 3600 }, 201);
	}
	if (path[0] === "servers" && path[1]) {
		const id = path[1];
		const server = await env.DB.prepare("SELECT * FROM servers WHERE id=? AND retired=0").bind(id).first<ServerRow>();
		if (!server) throw new HTTPError(404, "server not found");
		if (path.length === 2 && request.method === "DELETE") {
			await env.DB.batch([revision(env),
				env.DB.prepare("UPDATE servers SET retired=1,enabled=0,vendor_secret=NULL WHERE id=?").bind(id),
				audit(env, "server.retire", id, now)]);
			return json({ ok: true });
		}
		if (path.length === 2 && request.method === "PUT") {
			const value = await body(request);
			const name = text(value.name, "server name", 80);
			if (typeof value.enabled !== "boolean") throw new HTTPError(400, "enabled must be boolean");
			await env.DB.batch([revision(env),
				env.DB.prepare("UPDATE servers SET name=?,enabled=? WHERE id=?").bind(name, value.enabled ? 1 : 0, id),
				audit(env, "server.update", id, now)]);
			return json({ ok: true });
		}
		if (path[2] === "enrollment" && request.method === "POST") {
			if (server.agent_hash) throw new HTTPError(409, "enrolled agents cannot be replaced; register a new server identity");
			const token = randomToken();
			await env.DB.batch([
				env.DB.prepare("UPDATE servers SET enrollment_hash=?,enrollment_expires=? WHERE id=? AND agent_hash IS NULL")
					.bind(await hash(token), now + 3600, id),
				audit(env, "server.enrollment", id, now),
			]);
			return json({ enrollment_token: token, enrollment_expires: now + 3600 });
		}
		if (path[2] === "vendor" && request.method === "PUT") {
			const value = await body(request);
			const veid = text(value.veid, "VEID", 32), key = text(value.api_key, "API key", 512);
			if (!/^[0-9]+$/.test(veid)) throw new HTTPError(400, "VEID must be numeric");
			await env.DB.batch([
				env.DB.prepare(`UPDATE servers SET veid=?,vendor_secret=?,vendor_updated=NULL,vendor_total=NULL,
					vendor_used=NULL,vendor_reset=NULL,vendor_error=NULL WHERE id=?`)
					.bind(veid, await encrypt(key, env.CREDENTIAL_KEY, id), id),
				audit(env, "server.vendor", id, now),
			]);
			return json({ ok: true });
		}
		if (path[2] === "collect" && request.method === "POST") {
			if (!server.vendor_secret) throw new HTTPError(409, "configure Bandwagon credentials first");
			if (server.vendor_updated !== null && now - server.vendor_updated < 60) {
				throw new HTTPError(429, "wait at least one minute between successful collections");
			}
			await collectServer(env, server, now);
			const updated = await env.DB.prepare("SELECT vendor_error FROM servers WHERE id=?").bind(id).first<{ vendor_error: string | null }>();
			if (updated?.vendor_error) throw new HTTPError(502, updated.vendor_error);
			return json({ ok: true });
		}
	}
	if (path[0] === "users") {
		if (path[1] && path[2] === "token" && request.method === "POST") {
			const name = username(path[1]), token = randomToken();
			const updated = await env.DB.prepare("UPDATE users SET token_hash=? WHERE username=? RETURNING username")
				.bind(await hash(token), name).first();
			if (!updated) throw new HTTPError(404, "user not found");
			await audit(env, "user.token", name, now).run();
			return json({ username: name, subscription_path: `/s/${token}` });
		}
		if (path[1] && path[2] === "reset" && request.method === "POST") {
			const name = username(path[1]);
			if (name === "admin") throw new HTTPError(400, "admin has no personal usage");
			const existing = await env.DB.prepare("SELECT username FROM users WHERE username=?").bind(name).first();
			if (!existing) throw new HTTPError(404, "user not found");
			await env.DB.batch([revision(env),
				env.DB.prepare("UPDATE users SET period=period+1,revision=(SELECT revision FROM control WHERE id=1) WHERE username=?").bind(name),
				audit(env, "user.reset", name, now)]);
			return json({ ok: true });
		}
		if ((path.length === 1 && request.method === "POST") || (path.length === 2 && request.method === "PUT")) {
			const value = await body(request);
			const name = username(path[1] || value.username);
			const existing = await env.DB.prepare("SELECT username FROM users WHERE username=?").bind(name).first();
			if (request.method === "POST" && existing) throw new HTTPError(409, "user already exists");
			if (request.method === "PUT" && !existing) throw new HTTPError(404, "user not found");
			const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM users").first<{ n: number }>();
			if (!existing && (count?.n || 0) >= 100) throw new HTTPError(409, "this deployment supports at most 100 users");
			if (typeof value.enabled !== "boolean") throw new HTTPError(400, "enabled must be boolean");
			const quota = name === "admin" ? 0 : integer(value.quota_bytes, "quota_bytes");
			if (existing && name !== "admin") {
				const reserved = await env.DB.prepare(`SELECT COALESCE(SUM(MAX(g.grant_bytes,g.up+g.down)),0) AS n
					FROM usage g JOIN users u ON u.username=g.username AND u.period=g.period WHERE u.username=?`)
					.bind(name).first<{ n: number }>();
				if (quota < (reserved?.n || 0)) throw new HTTPError(409, "quota cannot be lower than issued reservations; disable the user or start a new period first");
			}
			const expiry = name === "admin" ? 0 : integer(value.expires_at, "expires_at");
			const day = name === "admin" ? 0 : integer(value.reset_day, "reset_day");
			if (day > 32) throw new HTTPError(400, "reset day must be 0 (manual), 1-31, or 32 (month end)");
			if (!Array.isArray(value.permissions) || value.permissions.length > 50) throw new HTTPError(400, "invalid permissions");
			const permissions = value.permissions.map(item => {
				if (!isRecord(item) || !Array.isArray(item.nodes) || item.nodes.length > 128) throw new HTTPError(400, "invalid node permissions");
				return { id: text(item.server_id, "server id"), nodes: item.nodes.map(n => text(n, "node tag")) };
			});
			if (new Set(permissions.map(p => p.id)).size !== permissions.length) throw new HTTPError(400, "duplicate server permission");
			const known = await env.DB.prepare("SELECT id FROM servers WHERE retired=0").all<{ id: string }>();
			if (permissions.some(p => !known.results.some(s => s.id === p.id))) throw new HTTPError(400, "unknown server permission");
			const token = randomToken();
			const statements = [revision(env)];
			if (!existing) {
				statements.push(env.DB.prepare(`INSERT INTO users(username,enabled,quota_bytes,expires_at,reset_day,next_reset,
					token_hash,created_at,revision) VALUES(?,?,?,?,?,?,?,?,(SELECT revision FROM control WHERE id=1))`)
					.bind(name, value.enabled ? 1 : 0, quota, expiry, day, nextReset(day, now), await hash(token), now));
			} else {
				statements.push(env.DB.prepare(`UPDATE users SET enabled=?,quota_bytes=?,expires_at=?,reset_day=?,next_reset=?,
					revision=(SELECT revision FROM control WHERE id=1) WHERE username=?`)
					.bind(value.enabled ? 1 : 0, quota, expiry, day, nextReset(day, now), name));
			}
			statements.push(env.DB.prepare("DELETE FROM permissions WHERE username=?").bind(name));
			for (const permission of permissions) {
				statements.push(env.DB.prepare("INSERT INTO permissions(username,server_id,nodes) VALUES(?,?,?)")
					.bind(name, permission.id, JSON.stringify(permission.nodes)));
			}
			statements.push(audit(env, existing ? "user.update" : "user.create", name, now));
			try {
				await env.DB.batch(statements);
			} catch (error) {
				if (error instanceof Error && error.message.includes("quota reservation conflict")) {
					throw new HTTPError(409, "quota changed concurrently with a reservation; refresh before retrying");
				}
				throw error;
			}
			return json({ ok: true, ...(!existing ? { subscription_path: `/s/${token}` } : {}) }, existing ? 200 : 201);
		}
	}
	throw new HTTPError(404, "not found");
}
