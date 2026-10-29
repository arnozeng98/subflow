import type { FORMAT, PROTOCOL } from "./constants.js";
import type { resolveConfig } from "./config.js";

export type Format = (typeof FORMAT)[keyof typeof FORMAT];
export type Protocol = (typeof PROTOCOL)[keyof typeof PROTOCOL];
export type Config = ReturnType<typeof resolveConfig>;
export type Scalar = string | number | null;

export interface Env {
	VPS_API_BASE_URL?: string;
	VPS_API_BEARER_TOKEN?: string;
	VPS_RAW_PATH_TEMPLATE?: string;
	REQUEST_TIMEOUT_MS?: string;
	TEMPLATE_CACHE_TTL_SECONDS?: string;
	RESPONSE_CACHE_CONTROL?: string;
	SUBFLOW_PROFILE_NAME?: string;
	SUBFLOW_DEFAULT_FORMAT?: string;
	SUBFLOW_CLASH_TEMPLATE_URL?: string;
	SUBFLOW_SINGBOX_TEMPLATE_URL?: string;
	SUBFLOW_SURGE_TEMPLATE_URL?: string;
	SUBFLOW_QUANTUMULTX_TEMPLATE_URL?: string;
	SUBFLOW_SHADOWROCKET_TEMPLATE_URL?: string;
	SUBFLOW_CLASH_RULES_BASE?: string;
	SUBFLOW_SINGBOX_GEOSITE_BASE?: string;
	SUBFLOW_SINGBOX_GEOIP_BASE?: string;
	SUBFLOW_BLACKMATRIX7_BASE?: string;
}

export interface RawUser {
	name?: string;
	username?: string;
	uuid?: string;
	password?: string;
	flow?: string;
}

export interface RawInbound {
	type?: string;
	tag?: string;
	listen_port?: Scalar;
	method?: string;
	password?: string;
	tls?: {
		server_name?: string;
		reality?: { enabled?: boolean; short_id?: string[] };
	};
	transport?: { type?: string; path?: string };
	users?: RawUser[];
}

export interface Usage {
	quota_gb?: Scalar;
	used_up_bytes?: Scalar;
	used_down_bytes?: Scalar;
	expire_at?: Scalar;
}

export interface RawPayload {
	schema_version?: 1;
	username?: string;
	enabled?: boolean;
	public_ip?: string;
	ws_domains?: { vless?: string; vmess?: string };
	meta?: Record<string, { public_key?: string }>;
	inbounds: RawInbound[];
	usage?: Usage | null;
}

export interface Node {
	name: string;
	protocol: Protocol;
	server: string;
	port: number;
	uuid: string;
	password: string;
	method: string;
	flow: string;
	sni: string;
	wsHost: string;
	wsPath: string;
	wsPathWithEarlyData: string;
	realityPublicKey: string;
	realityShortId: string;
}

export interface Subscription {
	contentType: string;
	body: string;
}

export interface TemplateContext {
	waitUntil(promise: Promise<void>): void;
}

export type GatewayContext = Omit<EventContext<Env, string, Record<string, never>>, "env"> & { env: Env };

export type JsonValue = null | boolean | number | string | JsonValue[] | JsonObject;
export interface JsonObject { [key: string]: JsonValue | undefined }

export function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalString(value: unknown): value is string | undefined {
	return value === undefined || typeof value === "string";
}

function optionalScalar(value: unknown): value is Scalar | undefined {
	return value === undefined || value === null || typeof value === "string" || typeof value === "number";
}

function isRawUser(value: unknown): value is RawUser {
	return isRecord(value) && ["name", "username", "uuid", "password", "flow"].every(
		(key) => optionalString(value[key]),
	);
}

function isRawInbound(value: unknown): value is RawInbound {
	if (!isRecord(value) || !["type", "tag", "method", "password"].every(
		(key) => optionalString(value[key]),
	) || !optionalScalar(value.listen_port)) return false;
	if (value.users !== undefined && (!Array.isArray(value.users) || !value.users.every(isRawUser))) return false;
	if (value.transport !== undefined && (!isRecord(value.transport) ||
		!optionalString(value.transport.type) || !optionalString(value.transport.path))) return false;
	if (value.tls !== undefined) {
		if (!isRecord(value.tls) || !optionalString(value.tls.server_name)) return false;
		const reality = value.tls.reality;
		if (reality !== undefined && (!isRecord(reality) ||
			(reality.enabled !== undefined && typeof reality.enabled !== "boolean") ||
			(reality.short_id !== undefined && (!Array.isArray(reality.short_id) ||
				!reality.short_id.every((item: unknown) => typeof item === "string"))))) return false;
	}
	return true;
}

export function isRawPayload(value: unknown): value is RawPayload {
	if (!isRecord(value) || value.schema_version !== 1 || !Array.isArray(value.inbounds) || !value.inbounds.every(isRawInbound) ||
		!optionalString(value.public_ip) || !optionalString(value.username) ||
		(value.enabled !== undefined && typeof value.enabled !== "boolean")) return false;
	if (value.ws_domains !== undefined && (!isRecord(value.ws_domains) ||
		!optionalString(value.ws_domains.vless) || !optionalString(value.ws_domains.vmess))) return false;
	if (value.meta !== undefined && (!isRecord(value.meta) || !Object.values(value.meta).every(
		(item) => isRecord(item) && optionalString(item.public_key),
	))) return false;
	return value.usage === undefined || value.usage === null ||
		(isRecord(value.usage) && ["quota_gb", "used_up_bytes", "used_down_bytes", "expire_at"].every(
			(key) => isRecord(value.usage) && optionalScalar(value.usage[key]),
		));
}

export function isJsonObject(value: unknown): value is JsonObject {
	return isRecord(value) && Object.values(value).every(isJsonValue);
}

function isJsonValue(value: unknown): value is JsonValue {
	return value === null || typeof value === "boolean" || typeof value === "number" ||
		typeof value === "string" || (Array.isArray(value) && value.every(isJsonValue)) || isJsonObject(value);
}
