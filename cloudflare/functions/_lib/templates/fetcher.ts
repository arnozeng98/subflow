/**
 * 可选远程模板按 URL 缓存；传输或缓存失败不会使内置模板失效。
 */
import type { TemplateContext } from "../types.js";

export async function fetchTemplate(url: string, ttlSeconds: number, ctx?: TemplateContext): Promise<string | null> {
	if (!url) return null;
	try {
		const cache = caches.default;
		const cacheKey = new Request(url, { method: "GET" });
		try {
			const cached = await cache.match(cacheKey);
			if (cached) return await cached.text();
		} catch {
			// Cache failures must not prevent fetching the optional template.
		}
		const response = await fetch(url, {
			method: "GET",
			headers: { accept: "text/plain, application/json, */*" },
			cf: { cacheTtl: ttlSeconds, cacheEverything: true },
		});
		if (!response.ok) return null;
		const body = await response.text();
		if (!body.trim()) return null;
		const toCache = new Response(body, {
			status: 200,
			headers: {
				"content-type": response.headers.get("content-type") || "text/plain; charset=utf-8",
				"cache-control": `public, max-age=${ttlSeconds}`,
			},
		});
		const write = Promise.resolve().then(() => cache.put(cacheKey, toCache)).catch(() => {});
		if (ctx) ctx.waitUntil(write);
		else await write;
		return body;
	} catch {
		return null;
	}
}
