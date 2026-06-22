/**
 * 基于 Cloudflare Cache API 的远程模板获取器。
 *
 * 用于从可靠源拉取运营方提供的《基础模板》（用于覆盖内置骨架的自定义模板）。
 * 获取结果以 URL 为键缓存在 `caches.default` 中，以免重复的订阅请求
 * 反复冲击上游源。
 *
 * 获取失败不是致命错误：调用方会回退到内置的完整骨架，因此不稳定的源
 * 绝不会导致订阅服务中断。
 */

/**
 * 获取远程文本资源，并缓存 `ttlSeconds` 秒。
 *
 * @param {string} url 要获取的绝对 URL。为空或虚值时返回 null。
 * @param {number} ttlSeconds 缓存存活时间。
 * @param {ExecutionContext} [ctx] Pages 上下文，用于延续缓存写入操作。
 * @returns {Promise<string|null>} 响应体文本；任何失败情况下返回 null。
 */
export async function fetchTemplate(url, ttlSeconds, ctx) {
	if (!url) {
		return null;
	}

	const cache = caches.default;
	const cacheKey = new Request(url, { method: "GET" });

	const cached = await cache.match(cacheKey);
	if (cached) {
		return await cached.text();
	}

	let response;
	try {
		response = await fetch(url, {
			method: "GET",
			headers: { accept: "text/plain, application/json, */*" },
			cf: { cacheTtl: ttlSeconds, cacheEverything: true },
		});
	} catch {
		return null;
	}

	if (!response.ok) {
		return null;
	}

	const body = await response.text();
	if (!body.trim()) {
		return null;
	}

	// 为 Cache API 层存入一份带有明确 TTL 的副本。
	const toCache = new Response(body, {
		status: 200,
		headers: {
			"content-type": response.headers.get("content-type") || "text/plain; charset=utf-8",
			"cache-control": `public, max-age=${ttlSeconds}`,
		},
	});
	const write = cache.put(cacheKey, toCache.clone());
	if (ctx && typeof ctx.waitUntil === "function") {
		ctx.waitUntil(write);
	} else {
		await write;
	}

	return body;
}
