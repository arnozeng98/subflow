import type { Env, RawPayload } from "../functions/_lib/types.js";

export interface CentralEnv extends Env {
	DB: D1Database;
	ADMIN_TOKEN: string;
	CREDENTIAL_KEY: string;
}

export interface UserRow {
	username: string;
	enabled: number;
	quota_bytes: number;
	period: number;
	expires_at: number;
	reset_day: number;
	next_reset: number;
	token_hash: string;
}

export interface ServerRow {
	id: string;
	name: string;
	enabled: number;
	enrollment_hash: string;
	enrollment_expires: number;
	instance_id: string | null;
	agent_hash: string | null;
	last_sequence: number;
	last_digest: string | null;
	last_response: string | null;
	applied_revision: number;
	last_seen: number | null;
	veid: string | null;
	vendor_secret: string | null;
	vendor_total: number | null;
	vendor_used: number | null;
	vendor_reset: number | null;
	vendor_multiplier: number | null;
	vendor_updated: number | null;
	vendor_error: string | null;
}

export interface UsageReport {
	username: string;
	period: number;
	up: number;
	down: number;
}

export interface SyncRequest {
	version: 1;
	sequence: number;
	applied_revision: number;
	reports: UsageReport[];
	payloads: Record<string, RawPayload>;
	inventory: { tag: string; type: string }[];
}

export class HTTPError extends Error {
	constructor(public readonly status: number, message: string) {
		super(message);
	}
}

export function json(value: unknown, status = 200): Response {
	return Response.json(value, {
		status,
		headers: { "cache-control": "no-store", "x-content-type-options": "nosniff", "referrer-policy": "no-referrer" },
	});
}

export function integer(value: unknown, label: string, min = 0): number {
	if (typeof value !== "number" || !Number.isSafeInteger(value) || value < min || value > 1_000_000_000_000_000) {
		throw new HTTPError(400, `${label} must be a safe nonnegative integer`);
	}
	return value;
}

export function text(value: unknown, label: string, max = 128): string {
	if (typeof value !== "string" || !value.trim() || value.length > max || /[\x00-\x1f\x7f]/.test(value)) {
		throw new HTTPError(400, `invalid ${label}`);
	}
	return value.trim();
}

export function username(value: unknown): string {
	const name = text(value, "username", 64);
	if (!/^[A-Za-z0-9_-]+$/.test(name) || ["__proto__", "prototype", "constructor"].includes(name)) throw new HTTPError(400, "invalid username");
	return name;
}
