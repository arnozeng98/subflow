import { isRecord } from "../functions/_lib/types.js";
import { HTTPError } from "./types.js";

const encoder = new TextEncoder();

export function randomToken(): string {
	return Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, "0")).join("");
}

export async function hash(value: string): Promise<string> {
	return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))),
		b => b.toString(16).padStart(2, "0")).join("");
}

export async function matches(value: string, expected: string): Promise<boolean> {
	const [a, b] = await Promise.all([hash(value), hash(expected)]);
	let difference = 0;
	for (let i = 0; i < a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
	return difference === 0;
}

export function bearer(request: Request): string {
	const header = request.headers.get("authorization") || "";
	if (!/^Bearer [A-Za-z0-9_-]{32,256}$/.test(header)) throw new HTTPError(401, "authentication required");
	return header.slice(7);
}

export async function body(request: Request): Promise<Record<string, unknown>> {
	if (!(request.headers.get("content-type") || "").startsWith("application/json")) {
		throw new HTTPError(415, "application/json required");
	}
	if (!request.body) throw new HTTPError(400, "request body required");
	const reader = request.body.getReader();
	const chunks: Uint8Array[] = [];
	let length = 0;
	for (;;) {
		const part = await reader.read();
		if (part.done) break;
		length += part.value.byteLength;
		if (length > 1024 * 1024) {
			await reader.cancel();
			throw new HTTPError(413, "request exceeds 1 MiB");
		}
		chunks.push(part.value);
	}
	const bytes = new Uint8Array(length);
	let offset = 0;
	for (const chunk of chunks) {
		bytes.set(chunk, offset);
		offset += chunk.length;
	}
	let value: unknown;
	try { value = JSON.parse(new TextDecoder().decode(bytes)); }
	catch { throw new HTTPError(400, "invalid JSON"); }
	if (!isRecord(value)) throw new HTTPError(400, "JSON object required");
	return value;
}

async function credentialKey(raw: string): Promise<CryptoKey> {
	if (!/^[a-f0-9]{64}$/.test(raw || "")) throw new Error("CREDENTIAL_KEY must contain 32 hex-encoded random bytes");
	const bytes = Uint8Array.from(raw.match(/../g) || [], b => parseInt(b, 16));
	return crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function encrypt(secret: string, rawKey: string, serverID: string): Promise<string> {
	const iv = crypto.getRandomValues(new Uint8Array(12));
	const encrypted = new Uint8Array(await crypto.subtle.encrypt(
		{ name: "AES-GCM", iv, additionalData: encoder.encode(serverID) },
		await credentialKey(rawKey), encoder.encode(secret),
	));
	return JSON.stringify({ v: 1, iv: [...iv], data: [...encrypted] });
}

export async function decrypt(secret: string, rawKey: string, serverID: string): Promise<string> {
	const value: unknown = JSON.parse(secret);
	if (!isRecord(value) || value.v !== 1 || !Array.isArray(value.iv) || value.iv.length !== 12 ||
		!Array.isArray(value.data) || ![...value.iv, ...value.data].every(
			b => typeof b === "number" && Number.isInteger(b) && b >= 0 && b < 256,
		)) throw new Error("invalid encrypted credential");
	return new TextDecoder().decode(await crypto.subtle.decrypt(
		{ name: "AES-GCM", iv: new Uint8Array(value.iv), additionalData: encoder.encode(serverID) },
		await credentialKey(rawKey), new Uint8Array(value.data),
	));
}
