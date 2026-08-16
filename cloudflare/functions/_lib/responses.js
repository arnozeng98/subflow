/**
 * 统一的 HTTP 响应构造。
 *
 * 把响应的生成集中到一处，能让安全响应头（nosniff）、缓存策略与错误语义在网关的
 * 每一条代码路径上保持一致。
 */

import { CONTENT_TYPE } from "./constants.js";

const SECURITY_HEADERS = Object.freeze({
	"x-content-type-options": "nosniff",
});

/** 一个成功的订阅响应，使用协商出的内容类型。 */
export function subscriptionResponse(body, contentType, cacheControl, userinfo) {
	const headers = {
		"content-type": contentType || CONTENT_TYPE.PLAIN,
		"cache-control": cacheControl || "no-store",
		...SECURITY_HEADERS,
	};
	if (userinfo) {
		// Shadowrocket、Clash Verge 等客户端会读取的标准配额/到期计量头。
		headers["Subscription-Userinfo"] = userinfo;
		// 许多客户端同样会遵循这个常见的订阅配置更新提示头。
		headers["Profile-Update-Interval"] = "24";
	}
	return new Response(body, {
		status: 200,
		headers,
	});
}

function errorResponse(status, message) {
	return new Response(message, {
		status,
		headers: {
			"content-type": CONTENT_TYPE.PLAIN,
			"cache-control": "no-store",
			...SECURITY_HEADERS,
		},
	});
}

/** 500：网关自身配置错误（缺少 VPS 基础 URL / token）。 */
export function misconfiguredResponse() {
	return errorResponse(500, "服务暂时不可用");
}

/** 502：VPS 数据 API 调用失败，或返回了无法使用的负载。 */
export function upstreamErrorResponse() {
	return errorResponse(502, "上游服务不可用");
}
