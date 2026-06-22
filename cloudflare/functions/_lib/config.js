/**
 * 运行时配置解析器。
 *
 * 这里是全项目唯一读取 Cloudflare 环境变量的地方。其他所有模块都只接收一个已经
 * 解析完成、校验过的配置对象，从不直接接触 `env`。这样可以把配置保持在外部
 *（由运维人员设置 env / secrets），并为“哪些东西是可配置的”提供一个明确的审查点。
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
 * 从 Cloudflare 的 `env` 构建出解析后的运行时配置。
 *
 * 即使必填项（VPS 基础 URL 与 bearer token）缺失，也会照样返回，以便调用方能够
 * 明确报出 500，而不是发起一个未携带认证的上游请求。
 */
export function resolveConfig(env) {
	const cacheTtl = positiveInteger(env.TEMPLATE_CACHE_TTL_SECONDS, DEFAULTS.TEMPLATE_CACHE_TTL_SECONDS);

	return {
		// VPS 数据 API 的连接信息。
		apiBaseUrl: normalizeBaseUrl(env.VPS_API_BASE_URL),
		bearerToken: nonEmptyString(env.VPS_API_BEARER_TOKEN),
		rawPathTemplate: nonEmptyString(env.VPS_RAW_PATH_TEMPLATE) || DEFAULTS.RAW_PATH_TEMPLATE,

		// 请求与缓存的调优参数。
		requestTimeoutMs: positiveInteger(env.REQUEST_TIMEOUT_MS, DEFAULTS.REQUEST_TIMEOUT_MS),
		templateCacheTtlSeconds: cacheTtl,
		responseCacheControl:
			nonEmptyString(env.RESPONSE_CACHE_CONTROL) || `public, s-maxage=${cacheTtl}, max-age=0`,

		// 呈现相关。
		profileName: nonEmptyString(env.SUBFLOW_PROFILE_NAME) || DEFAULTS.PROFILE_NAME,
		defaultFormat: nonEmptyString(env.SUBFLOW_DEFAULT_FORMAT) || DEFAULTS.DEFAULT_FORMAT,

		// 可选的完全远程基础模板（用于覆盖内置的骨架模板）。
		templateUrls: {
			clash: nonEmptyString(env.SUBFLOW_CLASH_TEMPLATE_URL),
			singbox: nonEmptyString(env.SUBFLOW_SINGBOX_TEMPLATE_URL),
			surge: nonEmptyString(env.SUBFLOW_SURGE_TEMPLATE_URL),
			quantumultx: nonEmptyString(env.SUBFLOW_QUANTUMULTX_TEMPLATE_URL),
			shadowrocket: nonEmptyString(env.SUBFLOW_SHADOWROCKET_TEMPLATE_URL),
		},

		// 官方规则源的基础地址（由生成的配置引用）。
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

/** 解析后的配置是否具备访问 VPS 数据 API 的条件。 */
export function hasUpstream(config) {
	return Boolean(config.apiBaseUrl && config.bearerToken);
}
