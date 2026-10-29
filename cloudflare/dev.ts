import { build } from "esbuild";
import { convertV4MiniflareOptions, Miniflare, Response as LocalResponse } from "miniflare";
import { readFile } from "node:fs/promises";
import { fileURLToPath, URL } from "node:url";
import { resolve } from "node:path";

async function bundle(path: string): Promise<string> {
	const output = await build({ entryPoints: [path], bundle: true, format: "esm", write: false, platform: "browser" });
	const script = output.outputFiles[0]?.text;
	if (!script) throw new Error(`Build failed: ${path}`);
	return script;
}

const [pages, central] = await Promise.all([bundle("cloudflare/worker.ts"), bundle("cloudflare/central/worker.ts")]);
const localAdmin = "local-development-only-admin-token-not-for-production";
const mf = new Miniflare(convertV4MiniflareOptions({
	host: "127.0.0.1", port: 8790, cf: false,
	workers: [
		{ name: "pages", modules: true, script: pages, compatibilityDate: "2026-06-08",
			serviceBindings: {
				CENTRAL: "central",
				ASSETS: async request => {
					const path = new URL(request.url).pathname;
					const assets: Record<string, string> = { "/index.html": "text/html; charset=utf-8", "/admin.js": "text/javascript; charset=utf-8", "/admin.css": "text/css; charset=utf-8" };
					if (!assets[path]) return new LocalResponse("Not Found", { status: 404 });
					const content = await readFile(resolve("cloudflare", "dist", path.slice(1)), "utf8");
					return new LocalResponse(content, { headers: { "content-type": assets[path] } });
				},
			},
		},
		{ name: "central", modules: true, script: central, compatibilityDate: "2026-06-08",
			d1Databases: ["DB"], bindings: { ADMIN_TOKEN: localAdmin, CREDENTIAL_KEY: "0".repeat(64) } },
	],
}));
try {
	const db = await mf.getD1Database("DB", "central");
	const migration = await readFile(fileURLToPath(new URL("./central/migrations/0001_central.sql", import.meta.url)), "utf8");
	const statements = migration.match(/CREATE TRIGGER[\s\S]*?END;|(?:CREATE|INSERT)[^;]+;/g);
	if (!statements) throw new Error("No local schema");
	await db.batch(statements.map(sql => db.prepare(sql)));
	console.log(`Local test server: ${await mf.ready}manage`);
	console.log(`Development-only admin token: ${localAdmin}`);
	console.log("In-memory data only. Do not enter real server credentials. Cron is not automatic locally.");
} catch (error) {
	await mf.dispose();
	throw error;
}
for (const signal of ["SIGINT", "SIGTERM"] as const) {
	process.once(signal, () => { void mf.dispose().then(() => process.exit(0), error => { console.error(error); process.exit(1); }); });
}
