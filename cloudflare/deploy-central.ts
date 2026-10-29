import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isRecord } from "./functions/_lib/types.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const apiBase = "https://api.cloudflare.com/client/v4";

export function deploymentConfig(databaseID: string, accountID: string, project: string, worker: string) {
	if (!/^[a-f0-9-]{36}$/.test(databaseID) || !/^[a-f0-9]{32}$/.test(accountID) ||
		![project, worker].every(n => /^[a-z][a-z0-9-]{2,50}$/.test(n))) throw new Error("invalid deployment identifiers");
	return {
		worker: {
			name: worker, account_id: accountID, main: join(root, "cloudflare", "central", "worker.ts"),
			compatibility_date: "2026-06-08", workers_dev: false, observability: { enabled: false },
			d1_databases: [{ binding: "DB", database_name: "subflow-central", database_id: databaseID,
				migrations_dir: join(root, "cloudflare", "central", "migrations") }],
			triggers: { crons: ["*/10 * * * *"] },
		},
		pages: {
			name: project, account_id: accountID, compatibility_date: "2026-06-08",
			pages_build_output_dir: join(root, "cloudflare", "dist"),
			services: [{ binding: "CENTRAL", service: worker }],
		},
	};
}

function required(name: string): string {
	const value = process.env[name]?.trim();
	if (!value) throw new Error(`Missing ${name}`);
	return value;
}

async function cloudflare(path: string, token: string, method = "GET", payload?: unknown): Promise<unknown> {
	const response = await fetch(apiBase + path, {
		method, headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
		...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
		redirect: "error", signal: AbortSignal.timeout(30000),
	});
	const result: unknown = await response.json();
	if (!response.ok || !isRecord(result) || result.success !== true) {
		throw new Error(`Cloudflare ${method} request failed (${response.status}); check token permissions and account configuration`);
	}
	return result.result;
}

function wrangler(args: string[], stdin?: string): Promise<void> {
	return new Promise((resolvePromise, reject) => {
		const child = spawn(process.execPath, [join(root, "node_modules", "wrangler", "bin", "wrangler.js"), ...args], {
			cwd: root, env: { ...process.env, WRANGLER_SEND_METRICS: "false" }, stdio: ["pipe", "inherit", "inherit"],
		});
		child.on("error", reject);
		child.on("exit", code => code === 0 ? resolvePromise() : reject(new Error(`Wrangler exited with status ${code}`)));
		child.stdin.on("error", reject);
		child.stdin.end(stdin);
	});
}

export async function deployCentral(): Promise<void> {
	const token = required("CLOUDFLARE_API_TOKEN"), account = required("CLOUDFLARE_ACCOUNT_ID");
	const adminToken = required("SUBFLOW_ADMIN_TOKEN"), credentialKey = required("SUBFLOW_CREDENTIAL_KEY");
	if (!/^[A-Za-z0-9_-]{32,256}$/.test(adminToken) || !/^[a-f0-9]{64}$/.test(credentialKey)) {
		throw new Error("Admin token must have at least 32 random characters; credential key must be 64 lowercase hex characters");
	}
	const project = process.env.SUBFLOW_PAGES_PROJECT || "subflow";
	const worker = process.env.SUBFLOW_WORKER_NAME || "subflow-central";
	deploymentConfig("00000000-0000-0000-0000-000000000000", account, project, worker);
	let database = process.env.SUBFLOW_D1_DATABASE_ID || "";
	const initialize = process.argv.includes("--initialize");
	if (!database) {
		if (!initialize) throw new Error("Set SUBFLOW_D1_DATABASE_ID; first deployment requires --initialize");
		const list = await cloudflare(`/accounts/${account}/d1/database?name=subflow-central`, token);
		if (!Array.isArray(list)) throw new Error("Invalid D1 listing");
		const candidates = list.filter(item => isRecord(item) && item.name === "subflow-central");
		if (candidates.length > 1) throw new Error("Multiple matching databases; set SUBFLOW_D1_DATABASE_ID explicitly");
		const found: unknown = candidates[0] || await cloudflare(`/accounts/${account}/d1/database`, token, "POST", { name: "subflow-central" });
		if (!isRecord(found) || typeof found.uuid !== "string") throw new Error("Invalid D1 database identifier");
		database = found.uuid;
	}
	const config = deploymentConfig(database, account, project, worker);
	const projects = await cloudflare(`/accounts/${account}/pages/projects`, token);
	if (!Array.isArray(projects)) throw new Error("Invalid Pages project listing");
	const existing = projects.find(p => isRecord(p) && p.name === project);
	if (!existing) {
		if (!initialize) throw new Error("Pages project does not exist; use --initialize");
		await cloudflare(`/accounts/${account}/pages/projects`, token, "POST", { name: project, production_branch: "main" });
	} else if (isRecord(existing) && existing.source) {
		throw new Error("Use a Direct Upload Pages project; do not mix Git-connected and Actions deployment");
	}
	const stage = await mkdtemp(join(tmpdir(), "subflow-central-deploy-"));
	try {
		const workerConfig = join(stage, "worker.json"), pagesConfig = join(stage, "wrangler.json");
		await writeFile(workerConfig, JSON.stringify(config.worker), { mode: 0o600 });
		await writeFile(pagesConfig, JSON.stringify(config.pages), { mode: 0o600 });
		await wrangler(["d1", "migrations", "apply", "DB", "--remote", "--config", workerConfig]);
		const keyHash = createHash("sha256").update(credentialKey).digest("hex");
		await wrangler(["d1", "execute", "DB", "--remote", "--config", workerConfig, "--command",
			`UPDATE control SET credential_key_hash='${keyHash}' WHERE id=1`]);
		await wrangler(["deploy", "--config", workerConfig, "--keep-vars"]);
		await wrangler(["secret", "bulk", "--config", workerConfig], JSON.stringify({ ADMIN_TOKEN: adminToken, CREDENTIAL_KEY: credentialKey }));
		await wrangler(["pages", "deploy", join(root, "cloudflare", "dist"), "--project-name", project,
			"--branch", "main", "--cwd", stage, "--commit-dirty=true"]);
		const url = `https://${project}.pages.dev/healthz`;
		let healthy = false;
		for (let attempt = 0; attempt < 6; attempt++) {
			try {
				const response = await fetch(url, { redirect: "error", signal: AbortSignal.timeout(15000) });
				const health: unknown = await response.json();
				healthy = response.ok && isRecord(health) && health.ok === true && health.version === 1;
			} catch {
				console.error(`Readiness check attempt ${attempt + 1} failed`);
			}
			if (healthy) break;
			await new Promise(resolvePromise => setTimeout(resolvePromise, 5000));
		}
		if (!healthy) throw new Error("Deployment uploaded, but central readiness check failed");
		console.log(`Central deployment ready: https://${project}.pages.dev/manage`);
		console.log(`Set repository variable SUBFLOW_D1_DATABASE_ID=${database} for future deployments.`);
		console.log("Keep SUBFLOW_CREDENTIAL_KEY unchanged: replacing it without re-encryption makes existing vendor credentials unreadable.");
	} finally {
		await rm(stage, { recursive: true, force: true });
	}
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	await deployCentral();
}
