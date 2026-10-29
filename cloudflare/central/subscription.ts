import { buildNodes } from "../functions/_lib/protocol.js";
import { isRawPayload } from "../functions/_lib/types.js";
import type { Node } from "../functions/_lib/types.js";
import { resolveConfig } from "../functions/_lib/config.js";
import { generate } from "../functions/_lib/templates/index.js";
import { negotiateFormat } from "../functions/_lib/format.js";
import { subscriptionResponse } from "../functions/_lib/responses.js";
import { hash } from "./security.js";
import { vendorSummary } from "./bandwagon.js";
import { HTTPError } from "./types.js";
import type { CentralEnv, ServerRow, UserRow } from "./types.js";

export async function subscription(request: Request, env: CentralEnv, token: string, now: number): Promise<Response> {
	if (!/^[a-f0-9]{64}$/.test(token)) throw new HTTPError(404, "not found");
	const user = await env.DB.prepare("SELECT * FROM users WHERE token_hash=?").bind(await hash(token)).first<UserRow>();
	if (!user || !user.enabled || (user.expires_at > 0 && user.expires_at <= now)) throw new HTTPError(404, "not found");
	const rows = await env.DB.prepare(`SELECT p.payload,s.name,s.id,a.nodes FROM payloads p
		JOIN servers s ON s.id=p.server_id JOIN permissions a ON a.server_id=s.id AND a.username=p.username
		JOIN users u ON u.username=p.username
		WHERE p.username=? AND s.enabled=1 AND p.revision>=u.revision AND p.updated_at>=?
			AND json_array_length(a.nodes)>0 ORDER BY s.id`).bind(user.username, now - 300)
		.all<{ payload: string; name: string; id: string; nodes: string }>();
	const nodes: Node[] = [];
	for (const row of rows.results) {
		const payload: unknown = JSON.parse(row.payload);
		if (!isRawPayload(payload)) throw new Error("corrupt stored subscription");
		const allowed: unknown = JSON.parse(row.nodes);
		if (!Array.isArray(allowed) || !allowed.every(n => typeof n === "string")) throw new Error("corrupt stored permission");
		payload.inbounds = payload.inbounds.filter(inbound => allowed.includes("*") || (inbound.tag !== undefined && allowed.includes(inbound.tag)));
		for (const [index, node] of buildNodes(payload).entries()) {
			nodes.push({ ...node, name: `${row.name} [${row.id.slice(0, 8)}] / ${node.name} #${index + 1}` });
		}
	}
	if (!nodes.length) throw new HTTPError(503, "no recently synchronized nodes");
	let usedUp = 0, usedDown = 0, total = user.quota_bytes;
	if (user.username === "admin") {
		const servers = await env.DB.prepare("SELECT vendor_total,vendor_used,vendor_updated,vendor_reset,vendor_error FROM servers WHERE retired=0")
			.all<ServerRow>();
		const summary = vendorSummary(servers.results, now);
		if (!summary.complete) throw new HTTPError(503, "server traffic is incomplete or stale");
		usedDown = summary.used;
		total = summary.total;
	} else {
		const usage = await env.DB.prepare("SELECT COALESCE(SUM(up),0) AS up,COALESCE(SUM(down),0) AS down FROM usage WHERE username=? AND period=?")
			.bind(user.username, user.period).first<{ up: number; down: number }>();
		usedUp = usage?.up || 0;
		usedDown = usage?.down || 0;
		if (usedUp + usedDown >= total) throw new HTTPError(404, "not found");
	}
	const config = resolveConfig(env);
	const format = negotiateFormat(new URL(request.url).searchParams.get("format"), request.headers.get("user-agent"), config.defaultFormat);
	const output = await generate(format, nodes, config);
	const usage = `upload=${usedUp}; download=${usedDown}; total=${total}${user.expires_at ? `; expire=${user.expires_at}` : ""}`;
	return subscriptionResponse(output.body, output.contentType, "no-store", usage);
}
