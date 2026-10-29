import { isRawPayload, isRecord } from "../functions/_lib/types.js";
import type { RawInbound, RawPayload } from "../functions/_lib/types.js";
import { bearer, body, hash } from "./security.js";
import { HTTPError, integer, json, text, username } from "./types.js";
import type { CentralEnv, ServerRow, SyncRequest, UsageReport } from "./types.js";

export function safePayload(raw: RawPayload, owner: string): RawPayload {
	const inbounds: RawInbound[] = raw.inbounds.map(inbound => {
		const users = (inbound.users || []).filter(user => {
			const identity = user.name || user.username || "";
			return identity && (identity.includes("@") ? identity.split("@")[1] : "admin") === owner;
		}).map(user => ({
			name: user.name, username: user.username, uuid: user.uuid, password: user.password, flow: user.flow,
		}));
		return {
			type: inbound.type, tag: inbound.tag, listen_port: inbound.listen_port, users,
			...(inbound.type === "shadowsocks" ? { method: inbound.method, password: inbound.password } : {}),
			...(inbound.transport ? { transport: { type: inbound.transport.type, path: inbound.transport.path } } : {}),
			...(inbound.tls ? { tls: {
				server_name: inbound.tls.server_name,
				...(inbound.tls.reality ? { reality: {
					enabled: inbound.tls.reality.enabled, short_id: inbound.tls.reality.short_id,
				} } : {}),
			} } : {}),
		};
	}).filter(inbound => inbound.users.length > 0);
	const meta: Record<string, { public_key?: string }> = {};
	for (const inbound of inbounds) {
		if (inbound.tag && raw.meta?.[inbound.tag]?.public_key) {
			meta[inbound.tag] = { public_key: raw.meta[inbound.tag]?.public_key };
		}
	}
	return {
		schema_version: 1, username: owner, enabled: raw.enabled,
		public_ip: raw.public_ip,
		ws_domains: raw.ws_domains ? { vless: raw.ws_domains.vless, vmess: raw.ws_domains.vmess } : undefined,
		meta, inbounds,
	};
}

function parseSync(value: Record<string, unknown>): SyncRequest {
	if (value.version !== 1) throw new HTTPError(400, "unsupported agent protocol");
	const sequence = integer(value.sequence, "sequence", 1);
	const revision = integer(value.applied_revision, "applied_revision");
	if (!Array.isArray(value.reports) || value.reports.length > 128 ||
		!isRecord(value.payloads) || Object.keys(value.payloads).length > 128 ||
		!Array.isArray(value.inventory) || value.inventory.length > 128) {
		throw new HTTPError(400, "invalid or oversized sync");
	}
	const seen = new Set<string>();
	const reports: UsageReport[] = value.reports.map(record => {
		if (!isRecord(record)) throw new HTTPError(400, "invalid usage report");
		const name = username(record.username), period = integer(record.period, "period", 1);
		if (name === "admin" || seen.has(`${name}/${period}`)) throw new HTTPError(400, "duplicate or admin usage report");
		seen.add(`${name}/${period}`);
		return { username: name, period, up: integer(record.up, "up"), down: integer(record.down, "down") };
	});
	const payloads: Record<string, RawPayload> = {};
	for (const [key, payload] of Object.entries(value.payloads)) {
		const name = username(key);
		if (!isRawPayload(payload) || payload.schema_version !== 1 || payload.inbounds.length > 128) {
			throw new HTTPError(400, "invalid payload schema");
		}
		payloads[name] = safePayload(payload, name);
	}
	const inventory = value.inventory.map(item => {
		if (!isRecord(item)) throw new HTTPError(400, "invalid inventory");
		return { tag: text(item.tag, "tag"), type: text(item.type, "type", 32) };
	});
	return { version: 1, sequence, applied_revision: revision, reports, payloads, inventory };
}

export async function enroll(request: Request, env: CentralEnv, now: number): Promise<Response> {
	const value = await body(request);
	if (value.version !== 1) throw new HTTPError(400, "unsupported agent protocol");
	const token = text(value.token, "token", 256);
	const instance = text(value.instance_id, "instance_id", 128);
	const agentToken = text(value.agent_token, "agent_token", 256);
	if (!/^[a-f0-9]{64}$/.test(agentToken)) throw new HTTPError(400, "invalid agent credential");
	const [tokenHash, agentHash] = await Promise.all([hash(token), hash(agentToken)]);
	const server = await env.DB.prepare("SELECT * FROM servers WHERE enrollment_hash=?").bind(tokenHash).first<ServerRow>();
	if (!server || !server.enabled) throw new HTTPError(401, "invalid enrollment");
	if (server.agent_hash) {
		if (server.agent_hash !== agentHash || server.instance_id !== instance) throw new HTTPError(409, "already enrolled");
		return json({ version: 1, server_id: server.id });
	}
	if (server.enrollment_expires < now) throw new HTTPError(401, "enrollment expired");
	await env.DB.prepare(`UPDATE servers SET agent_hash=?,instance_id=? WHERE id=? AND agent_hash IS NULL
		AND enrollment_expires>=?`).bind(agentHash, instance, server.id, now).run();
	const enrolled = await env.DB.prepare("SELECT agent_hash,instance_id FROM servers WHERE id=?")
		.bind(server.id).first<Pick<ServerRow, "agent_hash" | "instance_id">>();
	if (enrolled?.agent_hash !== agentHash || enrolled.instance_id !== instance) throw new HTTPError(409, "enrollment conflict");
	return json({ version: 1, server_id: server.id });
}

const desiredResponseSQL = `UPDATE servers SET last_response=json_object(
	'version',1,'revision',(SELECT revision FROM control WHERE id=1),
	'users',json(COALESCE((SELECT json_group_array(json_object(
		'username',u.username,'enabled',json(CASE WHEN u.enabled=1 AND servers.enabled=1
			AND (u.expires_at=0 OR u.expires_at>?) THEN 'true' ELSE 'false' END),
		'quota_bytes',u.quota_bytes,'period',u.period,
		'grant_bytes',COALESCE(g.grant_bytes,0),'expires_at',u.expires_at,'nodes',json(p.nodes)))
		FROM permissions p JOIN users u ON u.username=p.username
		LEFT JOIN usage g ON g.username=u.username AND g.server_id=p.server_id AND g.period=u.period
		WHERE p.server_id=servers.id),'[]'))) WHERE id=?`;

export async function synchronize(request: Request, env: CentralEnv, now: number): Promise<Response> {
	const id = text(request.headers.get("x-subflow-server"), "server id");
	const agentHash = await hash(bearer(request));
	const server = await env.DB.prepare("SELECT * FROM servers WHERE id=? AND agent_hash=?").bind(id, agentHash).first<ServerRow>();
	if (!server) throw new HTTPError(401, "invalid agent");
	const sync = parseSync(await body(request));
	const digest = await hash(JSON.stringify(sync));
	if (sync.sequence === server.last_sequence && digest === server.last_digest && server.last_response) {
		return new Response(server.last_response, { headers: { "content-type": "application/json", "cache-control": "no-store" } });
	}
	if (sync.sequence !== server.last_sequence + 1) throw new HTTPError(409, "sequence conflict");
	const issued: unknown = server.last_response ? JSON.parse(server.last_response) : null;
	if (sync.applied_revision > (isRecord(issued) ? integer(issued.revision, "stored revision") : 0) ||
		sync.applied_revision < server.applied_revision) throw new HTTPError(409, "invalid applied revision");

	const existing = await env.DB.prepare("SELECT username,period FROM usage WHERE server_id=?").bind(id)
		.all<{ username: string; period: number }>();
	const authorized = new Set(existing.results.map(row => `${row.username}/${row.period}`));
	for (const report of sync.reports) {
		if (!authorized.has(`${report.username}/${report.period}`)) throw new HTTPError(409, "usage has no issued grant");
	}
	const statements: D1PreparedStatement[] = [
		env.DB.prepare(`UPDATE servers SET last_sequence=?,last_digest=?,last_seen=?,applied_revision=?,inventory=? WHERE id=?`)
			.bind(sync.sequence, digest, now, sync.applied_revision, JSON.stringify(sync.inventory), id),
	];
	if (sync.reports.length) {
		const reports = JSON.stringify(sync.reports);
		const match = "json_extract(r.value,'$.username')=g.username AND json_extract(r.value,'$.period')=g.period";
		statements.push(env.DB.prepare(`UPDATE usage AS g SET
			up=(SELECT json_extract(r.value,'$.up') FROM json_each(?) r WHERE ${match}),
			down=(SELECT json_extract(r.value,'$.down') FROM json_each(?) r WHERE ${match})
			WHERE server_id=? AND EXISTS(SELECT 1 FROM json_each(?) r WHERE ${match})`)
			.bind(reports, reports, id, reports));
	}
	statements.push(env.DB.prepare(`INSERT OR IGNORE INTO usage(username,server_id,period)
		SELECT u.username,p.server_id,u.period FROM users u JOIN permissions p ON p.username=u.username
		WHERE p.server_id=? AND u.username<>'admin'`).bind(id));
	// One transaction serializes reservations across all servers. Unspent grants are not recycled.
	statements.push(env.DB.prepare(`UPDATE usage AS g SET grant_bytes=MAX(grant_bytes,up+down)+
		MIN(67108864,MAX(0,(SELECT quota_bytes FROM users WHERE username=g.username)-
		(SELECT COALESCE(SUM(MAX(x.grant_bytes,x.up+x.down)),0) FROM usage x
		 WHERE x.username=g.username AND x.period=g.period)))
		WHERE server_id=? AND grant_bytes-up-down<33554432 AND EXISTS(
			SELECT 1 FROM users u JOIN permissions p ON p.username=u.username JOIN servers s ON s.id=p.server_id
			WHERE u.username=g.username AND u.period=g.period AND p.server_id=g.server_id
				AND u.enabled=1 AND s.enabled=1 AND (u.expires_at=0 OR u.expires_at>?)
				AND json_array_length(p.nodes)>0)`).bind(id, now));
	statements.push(env.DB.prepare("DELETE FROM payloads WHERE server_id=?").bind(id));
	statements.push(env.DB.prepare(`INSERT INTO payloads(server_id,username,payload,revision,updated_at)
		SELECT ?,p.key,p.value,?,? FROM json_each(?) p JOIN users u ON u.username=p.key
		JOIN permissions a ON a.username=u.username AND a.server_id=?`)
		.bind(id, sync.applied_revision, now, JSON.stringify(sync.payloads), id));
	statements.push(env.DB.prepare(desiredResponseSQL).bind(now, id));
	statements.push(env.DB.prepare("SELECT last_response FROM servers WHERE id=?").bind(id));
	try {
		const results = await env.DB.batch<{ last_response: string }>(statements);
		const response = results.at(-1)?.results[0]?.last_response;
		if (!response) throw new Error("missing committed sync response");
		return new Response(response, { headers: { "content-type": "application/json", "cache-control": "no-store" } });
	} catch (error) {
		if (error instanceof Error && /sequence conflict|counter regression/.test(error.message)) {
			throw new HTTPError(409, "sequence conflict or counter regression; retry the pending request");
		}
		throw error;
	}
}
