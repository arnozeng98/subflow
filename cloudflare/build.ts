import { copyFile, mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath, URL } from "node:url";
import { join } from "node:path";
import { build } from "esbuild";

const root = fileURLToPath(new URL("..", import.meta.url));
const outdir = fileURLToPath(new URL("./dist", import.meta.url));
await mkdir(outdir, { recursive: true });
const result = await build({
	absWorkingDir: root,
	entryPoints: [join("cloudflare", "worker.ts")],
	outfile: join(outdir, "_worker.js"),
	bundle: true,
	format: "esm",
	platform: "browser",
	target: "es2022",
	metafile: true,
	legalComments: "none",
});
if (Object.values(result.metafile.outputs).some((output) => output.imports.length > 0)) {
	throw new Error("The Pages worker must be self-contained");
}
await writeFile(new URL("./dist/_routes.json", import.meta.url),
	JSON.stringify({ version: 1, include: ["/*"], exclude: [] }) + "\n");
await writeFile(new URL("./dist/404.html", import.meta.url),
	"<!doctype html><html lang=\"en\"><title>Not Found</title><h1>Not Found</h1></html>\n");
await build({
	entryPoints: [fileURLToPath(new URL("./admin/client.ts", import.meta.url))],
	outfile: join(outdir, "admin.js"), bundle: true, format: "esm", platform: "browser", target: "es2022",
});
await copyFile(new URL("./admin/index.html", import.meta.url), join(outdir, "index.html"));
await copyFile(new URL("./admin/admin.css", import.meta.url), join(outdir, "admin.css"));
console.log("Built cloudflare/dist/_worker.js (Cloudflare Pages advanced mode)");
