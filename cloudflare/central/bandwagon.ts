import { isRecord } from "../functions/_lib/types.js";
import { decrypt } from "./security.js";
import type { CentralEnv, ServerRow } from "./types.js";

export interface VendorTraffic {
	total: number;
	used: number;
	reset: number;
	multiplier: number;
}

function numeric(value: unknown, name: string): number {
	if ((typeof value !== "number" && typeof value !== "string") || String(value).trim() === "") {
		throw new Error(`KiwiVM missing ${name}`);
	}
	const result = Number(value);
	if (!Number.isFinite(result) || result < 0) throw new Error(`KiwiVM invalid ${name}`);
	return result;
}

export function parseTraffic(value: unknown): VendorTraffic {
	if (!isRecord(value) || value.error !== 0) throw new Error("KiwiVM API reported failure");
	const multiplier = numeric(value.monthly_data_multiplier, "monthly_data_multiplier");
	if (multiplier <= 0) throw new Error("KiwiVM invalid multiplier");
	const total = Math.floor(numeric(value.plan_monthly_data, "plan_monthly_data") * multiplier);
	const used = Math.floor(numeric(value.data_counter, "data_counter") * multiplier);
	const reset = numeric(value.data_next_reset, "data_next_reset");
	if (![total, used, reset].every(Number.isSafeInteger) || reset <= 0) {
		throw new Error("KiwiVM traffic or reset exceeds supported range");
	}
	return { total, used, reset, multiplier };
}

export async function collectServer(env: CentralEnv, server: ServerRow, now: number): Promise<void> {
	if (!server.veid || !server.vendor_secret) return;
	let phase = "credential";
	try {
		const apiKey = await decrypt(server.vendor_secret, env.CREDENTIAL_KEY, server.id);
		phase = "request";
		const response = await fetch("https://api.64clouds.com/v1/getServiceInfo", {
			method: "POST",
			body: new URLSearchParams({ veid: server.veid, api_key: apiKey }),
			redirect: "manual",
			signal: AbortSignal.timeout(15000),
		});
		if (!response.ok) throw new Error(`KiwiVM HTTP ${response.status}`);
		phase = "decode";
		const raw = await response.text();
		if (raw.length > 256 * 1024) throw new Error("KiwiVM response too large");
		const traffic = parseTraffic(JSON.parse(raw));
		phase = "persistence";
		await env.DB.prepare(`UPDATE servers SET vendor_total=?,vendor_used=?,vendor_reset=?,
			vendor_multiplier=?,vendor_updated=?,vendor_error=NULL WHERE id=? AND vendor_secret=?`)
			.bind(traffic.total, traffic.used, traffic.reset, traffic.multiplier, now, server.id, server.vendor_secret).run();
	} catch (error) {
		// Provider bodies and transport URLs can contain credentials; never persist them.
		console.error("Bandwagon collection failed", { server: server.id, phase, errorType: error instanceof Error ? error.name : "unknown" });
		await env.DB.prepare("UPDATE servers SET vendor_error=? WHERE id=? AND vendor_secret=?")
			.bind("Bandwagon collection failed; check credentials and provider availability", server.id, server.vendor_secret).run();
	}
}

export function vendorSummary(servers: Pick<ServerRow, "vendor_total" | "vendor_used" | "vendor_updated" | "vendor_reset" | "vendor_error">[], now: number) {
	const complete = servers.length > 0 && servers.every(s => s.vendor_total !== null && s.vendor_used !== null &&
		s.vendor_updated !== null && s.vendor_updated >= now - 1800 && s.vendor_reset !== null &&
		s.vendor_reset > now && !s.vendor_error);
	let used = 0, remaining = 0;
	for (const server of servers) {
		if (server.vendor_used !== null && server.vendor_total !== null) {
			used += server.vendor_used;
			remaining += Math.max(0, server.vendor_total - server.vendor_used);
		}
	}
	if (!Number.isSafeInteger(used + remaining)) throw new Error("aggregate traffic overflow");
	return { complete, used, remaining, total: used + remaining };
}
