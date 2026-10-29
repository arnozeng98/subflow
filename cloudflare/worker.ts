import { onRequestGet } from "./functions/[user].js";
import type { Env, GatewayContext } from "./functions/_lib/types.js";

export interface WorkerEnv extends Env {
	ASSETS?: Pick<Fetcher, "fetch">;
	CENTRAL?: Pick<Fetcher, "fetch">;
}

export default {
	async fetch(request: GatewayContext["request"], env: WorkerEnv, ctx: Pick<ExecutionContext, "waitUntil" | "passThroughOnException">) {
		const next = () => env.ASSETS
			? env.ASSETS.fetch(request)
			: Promise.resolve(new Response("Not Found", { status: 404 }));
		const path = new URL(request.url).pathname;
		if (env.CENTRAL) {
			if (path.startsWith("/admin/") || path.startsWith("/agent/") || path.startsWith("/s/") || path === "/healthz") {
				return env.CENTRAL.fetch(request);
			}
			if (request.method === "GET" && ["/", "/manage", "/admin.js", "/admin.css"].includes(path) && env.ASSETS) {
				const url = new URL(request.url);
				if (path === "/" || path === "/manage") url.pathname = "/index.html";
				const asset = await env.ASSETS.fetch(new Request(url, request));
				const response = new Response(asset.body, asset);
				response.headers.set("cache-control", "no-store");
				response.headers.set("referrer-policy", "no-referrer");
				response.headers.set("x-content-type-options", "nosniff");
				response.headers.set("content-security-policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'");
				return response;
			}
			return new Response("Not Found", { status: 404, headers: { "cache-control": "no-store" } });
		}
		const match = /^\/([^/]+)\/?$/.exec(path);
		if (request.method !== "GET" || !match?.[1]) return next();
		let user: string;
		try {
			user = decodeURIComponent(match[1]);
		} catch {
			return next();
		}
		return onRequestGet({
			request,
			env,
			params: { user },
			next,
			data: {},
			functionPath: "/[user]",
			waitUntil: ctx.waitUntil.bind(ctx),
			passThroughOnException: ctx.passThroughOnException.bind(ctx),
		});
	},
} satisfies ExportedHandler<WorkerEnv>;
