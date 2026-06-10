/**
 * Runtime configuration resolver.
 *
 * This is the single place where Cloudflare environment variables are read. Every
 * other module receives an already-resolved, validated config object and never
 * touches `env` directly. That keeps configuration external (operators set env /
 * secrets) and gives us one obvious audit point for "what is configurable".
 */

import { CONTENT_TYPE, DEFAULTS, RULE_SOURCES } from "./constants.js";

function nonEmptyString(value) {
	return typeof value === "string" && value.trim() !== "" ? value.trim() : "";
}

function positiveInteger(value, fallback) {
	const numeric = Number.parseInt(value, 10);
	return Number.isInteger(numeric) && numeric > 0 ? numeric : fallback;
}

function normalizeBaseUrl(value) {
	const trimmed = nonEmptyString(value);
	if (!trimmed) {
		return "";
	}
	return trimmed.endsWith("/") ? trimmed.slice(0, -1) : trimmed;
}

/**
 * Build the resolved runtime config from Cloudflare `env`.
 *
 * Required values (VPS base URL + bearer token) are returned even when missing so
 * the caller can surface a clear 500 instead of attempting an unauthenticated
 * upstream call.
 */
export function resolveConfig(env) {
	const cacheTtl = positiveInteger(env.TEMPLATE_CACHE_TTL_SECONDS, DEFAULTS.TEMPLATE_CACHE_TTL_SECONDS);

	return {
		// VPS data API connection.
		apiBaseUrl: normalizeBaseUrl(env.VPS_API_BASE_URL),
		bearerToken: nonEmptyString(env.VPS_API_BEARER_TOKEN),
		rawPathTemplate: nonEmptyString(env.VPS_RAW_PATH_TEMPLATE) || DEFAULTS.RAW_PATH_TEMPLATE,

		// Request + cache tuning.
		requestTimeoutMs: positiveInteger(env.REQUEST_TIMEOUT_MS, DEFAULTS.REQUEST_TIMEOUT_MS),
		templateCacheTtlSeconds: cacheTtl,
		responseCacheControl:
			nonEmptyString(env.RESPONSE_CACHE_CONTROL) || `public, s-maxage=${cacheTtl}, max-age=0`,

		// Presentation.
		profileName: nonEmptyString(env.SUBFLOW_PROFILE_NAME) || DEFAULTS.PROFILE_NAME,
		defaultFormat: nonEmptyString(env.SUBFLOW_DEFAULT_FORMAT) || DEFAULTS.DEFAULT_FORMAT,

		// Optional fully-remote base templates (override the built-in skeletons).
		templateUrls: {
			clash: nonEmptyString(env.SUBFLOW_CLASH_TEMPLATE_URL),
			singbox: nonEmptyString(env.SUBFLOW_SINGBOX_TEMPLATE_URL),
			surge: nonEmptyString(env.SUBFLOW_SURGE_TEMPLATE_URL),
			quantumultx: nonEmptyString(env.SUBFLOW_QUANTUMULTX_TEMPLATE_URL),
			shadowrocket: nonEmptyString(env.SUBFLOW_SHADOWROCKET_TEMPLATE_URL),
		},

		// Official rule source bases (referenced by generated configs).
		ruleSources: {
			clashRulesBase: normalizeBaseUrl(env.SUBFLOW_CLASH_RULES_BASE) || RULE_SOURCES.CLASH_RULES_BASE,
			singboxGeositeBase:
				normalizeBaseUrl(env.SUBFLOW_SINGBOX_GEOSITE_BASE) || RULE_SOURCES.SINGBOX_GEOSITE_BASE,
			singboxGeoipBase:
				normalizeBaseUrl(env.SUBFLOW_SINGBOX_GEOIP_BASE) || RULE_SOURCES.SINGBOX_GEOIP_BASE,
			blackmatrix7Base:
				normalizeBaseUrl(env.SUBFLOW_BLACKMATRIX7_BASE) || RULE_SOURCES.BLACKMATRIX7_BASE,
		},

		contentType: CONTENT_TYPE,
	};
}

/** Whether the resolved config can reach the VPS data API. */
export function hasUpstream(config) {
	return Boolean(config.apiBaseUrl && config.bearerToken);
}
