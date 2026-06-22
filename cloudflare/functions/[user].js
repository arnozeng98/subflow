/**
 * 公共订阅网关（Cloudflare Pages Function）。
 *
 * 本文件仅作为入口与编排层。它负责校验用户名、从 VPS 数据 API 拉取用户的
 * 原始节点数据、协商客户端格式，并把完整的配置生成工作委托给 `_lib` 下的各模块。
 *
 * 所有配置的拼装都在 Cloudflare 这一侧完成：VPS 只负责对外暴露数据，本层则
 * 基于官方且持续更新的规则源来构建每一种客户端配置。对于不存在的用户，请求会
 * 直接落到 Cloudflare 原生的 404，因此枚举探测不会得到任何与业务相关的信号。
 */

import { USERNAME_PATTERN } from "./_lib/constants.js";
import { resolveConfig, hasUpstream } from "./_lib/config.js";
import { fetchRawPayload } from "./_lib/raw-client.js";
import { buildNodes } from "./_lib/protocol.js"; 

import { negotiateFormat } from "./_lib/format.js";
import { generate } from "./_lib/templates/index.js";
import { buildSubscriptionUserinfo } from "./_lib/userinfo.js";
import {
	subscriptionResponse,
	misconfiguredResponse,
	upstreamErrorResponse,
} from "./_lib/responses.js";

export async function onRequestGet(context) {
	const { request, env, params, next, waitUntil } = context;

	const username = typeof params?.user === "string" ? params.user.trim() : "";
	if (!username || !USERNAME_PATTERN.test(username)) {
		return next();
	}

	const config = resolveConfig(env);
	if (!hasUpstream(config)) {
		return misconfiguredResponse();
	}

	let raw;
	try {
		const result = await fetchRawPayload(config, username, request);
		if (result.kind === "not-found") {
			return next();
		}
		if (result.kind !== "ok") {
			return upstreamErrorResponse();
		}
		raw = result.data;
	} catch {
		return upstreamErrorResponse();
	}

	const nodes = buildNodes(raw);
	if (nodes.length === 0) {
		return next();
	}

	const url = new URL(request.url);
	const format = negotiateFormat(
		url.searchParams.get("format"),
		request.headers.get("user-agent"),
		config.defaultFormat,
	);

	try {
		const { contentType, body } = await generate(format, nodes, config, { waitUntil });
		const userinfo = buildSubscriptionUserinfo(raw?.usage);
		return subscriptionResponse(body, contentType, config.responseCacheControl, userinfo);
	} catch {
		return upstreamErrorResponse();
	}
}
