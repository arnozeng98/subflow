/**
 * Remote template fetcher backed by the Cloudflare Cache API.
 *
 * Used to pull an operator-supplied *base template* (an override for a built-in
 * skeleton) from a reliable source. Results are cached in `caches.default` keyed
 * by URL so repeated subscription requests do not hammer the upstream source.
 *
 * Failures are non-fatal: the caller falls back to the bundled complete skeleton,
 * so a flaky source can never take subscriptions down.
 */

/**
 * Fetch a remote text resource, caching it for `ttlSeconds`.
 *
 * @param {string} url Absolute URL to fetch. Empty/falsy returns null.
 * @param {number} ttlSeconds Cache lifetime.
 * @param {ExecutionContext} [ctx] Pages context, used to extend cache writes.
 * @returns {Promise<string|null>} The body text, or null on any failure.
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

	// Store a copy with an explicit TTL for the Cache API layer.
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
