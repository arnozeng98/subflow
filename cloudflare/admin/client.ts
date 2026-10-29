interface Server {
	id: string; name: string; enabled: number; enrolled: number; last_seen: number | null;
	applied_revision: number; inventory: string; vendor_total: number | null; vendor_used: number | null;
	vendor_reset: number | null; vendor_updated: number | null; vendor_error: string | null;
}
interface User {
	username: string; enabled: number; quota_bytes: number; period: number; up: number; down: number;
	reserved: number; expires_at: number; reset_day: number;
}
interface Overview {
	now: number; revision: number; summary: { complete: boolean; used: number; remaining: number };
	servers: Server[]; users: User[]; permissions: { username: string; server_id: string; nodes: string }[];
	audit: { action: string; target: string; created_at: number }[];
}
function element<T extends HTMLElement>(id: string, ctor: { new(): T }): T {
	const value = document.getElementById(id);
	if (!(value instanceof ctor)) throw new Error(`Missing ${id}`);
	return value;
}
const message = element("message", HTMLParagraphElement);
const userForm = element("user-edit", HTMLFormElement);
const loginForm = element("login", HTMLFormElement);
let token = "", editing = false;
let data: Overview | null = null;

function notify(value: string, error = false) {
	message.textContent = value;
	message.className = error ? "error" : "";
}
async function api<T>(path: string, method = "GET", value?: unknown): Promise<T> {
	const response = await fetch(`/admin/${path}`, {
		method, headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
		...(value === undefined ? {} : { body: JSON.stringify(value) }),
		cache: "no-store", redirect: "error",
	});
	const result = await response.json();
	if (!response.ok) throw new Error(result.error || `HTTP ${response.status}`);
	return result as T;
}
function bytes(value: number): string { return `${(value / 2 ** 30).toFixed(2)} GiB`; }
function date(value: number | null): string { return value ? new Date(value * 1000).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai" }) : "未知 / 无"; }
function cell(row: HTMLTableRowElement, value: string) {
	const td = document.createElement("td"); td.textContent = value; row.append(td); return td;
}
function action(parent: HTMLElement, label: string, run: () => Promise<void> | void) {
	const button = document.createElement("button"); button.type = "button"; button.textContent = label;
	button.addEventListener("click", () => { void execute(run); }); parent.append(button);
}
async function execute(run: () => Promise<void> | void) {
	try { notify("处理中…"); await run(); notify("完成"); }
	catch (error) { notify(error instanceof Error ? error.message : "操作失败", true); }
}
function reveal(value: string) {
	element("secret", HTMLTextAreaElement).value = value;
	const details = element("secret", HTMLTextAreaElement).closest("details");
	if (details) details.open = true;
}
function input(name: string): HTMLInputElement {
	const item = userForm.elements.namedItem(name);
	if (!(item instanceof HTMLInputElement)) throw new Error(`Missing ${name}`);
	return item;
}
function permissionForm(name: string) {
	const root = element("permissions", HTMLDivElement); root.replaceChildren();
	for (const server of data?.servers || []) {
		const label = document.createElement("label"); label.textContent = server.name;
		const select = document.createElement("select"); select.multiple = true; select.dataset.server = server.id;
		const current = data?.permissions.find(p => p.username === name && p.server_id === server.id);
		const selected: string[] = current ? JSON.parse(current.nodes) : [];
		const nodes: { tag: string }[] = JSON.parse(server.inventory);
		for (const tag of new Set(["*", ...nodes.map(n => n.tag), ...selected])) {
			const option = document.createElement("option"); option.value = tag;
			option.textContent = tag === "*" ? "全部节点（含以后新增）" : tag;
			option.selected = selected.includes(tag); select.append(option);
		}
		label.append(select); root.append(label);
	}
}
function edit(user?: User) {
	editing = !!user; userForm.reset();
	input("username").readOnly = editing; input("username").value = user?.username || "";
	input("quota").value = String((user?.quota_bytes ?? 100 * 2 ** 30) / 2 ** 30);
	input("enabled").checked = user ? !!user.enabled : true;
	input("reset_day").value = String(user?.reset_day || 0);
	input("expires").value = user?.expires_at ? new Date((user.expires_at + 8 * 3600) * 1000).toISOString().slice(0, 10) : "";
	for (const name of ["quota", "reset_day", "expires"]) input(name).disabled = user?.username === "admin";
	element("user-heading", HTMLHeadingElement).textContent = editing ? `编辑 ${user?.username}` : "创建用户";
	permissionForm(user?.username || "");
}
async function refresh() {
	data = await api<Overview>("overview");
	element("dashboard", HTMLElement).hidden = false; loginForm.hidden = true;
	element("summary", HTMLParagraphElement).textContent =
		`${data.summary.complete ? "套餐汇总" : "数据不完整：仅展示已知部分"} · 已用 ${bytes(data.summary.used)} · 剩余 ${bytes(data.summary.remaining)}`;
	element("freshness", HTMLParagraphElement).textContent = `刷新于 ${date(data.now)} · 中央配置版本 ${data.revision} · 原始流量，不作双倍显示`;
	const servers = element("servers", HTMLTableSectionElement); servers.replaceChildren();
	const vendorSelect = element("vendor-server", HTMLSelectElement); vendorSelect.replaceChildren();
	for (const server of data.servers) {
		const row = servers.insertRow();
		cell(row, `${server.name}\n${server.id}`);
		cell(row, !server.enabled ? "已暂停" : !server.enrolled ? "待注册" :
			server.last_seen && data.now - server.last_seen < 180 ? "在线" : "离线");
		cell(row, `${server.applied_revision} / ${data.revision}\n${date(server.last_seen)}`);
		cell(row, server.vendor_total === null || server.vendor_used === null ? "待采集" :
			`${bytes(server.vendor_used)} / ${bytes(Math.max(0, server.vendor_total - server.vendor_used))}`);
		cell(row, `${date(server.vendor_reset)}\n${date(server.vendor_updated)}\n${server.vendor_error || ""}`);
		const controls = cell(row, "");
		action(controls, "采集", async () => { await api(`servers/${server.id}/collect`, "POST", {}); await refresh(); });
		action(controls, server.enabled ? "暂停" : "启用", async () => {
			if (!confirm("变更服务器状态？停用将在下次同步生效，已发放额度不会转给其他服务器。")) return;
			await api(`servers/${server.id}`, "PUT", { name: server.name, enabled: !server.enabled }); await refresh();
		});
		action(controls, "移除", async () => {
			if (!confirm("退役并移出当前服务器汇总？历史用量和已发额度会保留；请先停止 VPS 上的服务，离线节点不能被即时撤销。此操作不能恢复原节点身份。")) return;
			await api(`servers/${server.id}`, "DELETE"); await refresh();
		});
		if (!server.enrolled) action(controls, "重发注册凭证", async () => {
			const result = await api<{ enrollment_token: string }>(`servers/${server.id}/enrollment`, "POST", {});
			reveal(result.enrollment_token);
		});
		const option = document.createElement("option"); option.value = server.id; option.textContent = server.name; vendorSelect.append(option);
	}
	const users = element("users", HTMLTableSectionElement); users.replaceChildren();
	for (const user of data.users) {
		const row = users.insertRow(), isAdmin = user.username === "admin";
		cell(row, user.username); cell(row, `${user.enabled ? "启用" : "停用"} / ${user.period}`);
		cell(row, isAdmin ? "服务器套餐汇总；无个人计量" : `${bytes(user.up + user.down)} / ${bytes(Math.max(0, user.quota_bytes - user.up - user.down))}`);
		cell(row, isAdmin ? "不适用" : bytes(user.reserved)); cell(row, date(user.expires_at));
		const controls = cell(row, "");
		action(controls, "编辑", () => { edit(user); userForm.scrollIntoView({ behavior: "smooth" }); });
		action(controls, "生成 / 更换订阅", async () => {
			if (!confirm("生成新链接会立即使旧订阅链接失效，已下载的节点凭据不因此撤销。继续？")) return;
			const result = await api<{ subscription_path: string }>(`users/${user.username}/token`, "POST", {});
			reveal(new URL(result.subscription_path, location.origin).href);
		});
		if (!isAdmin) action(controls, "重置额度", async () => {
			if (!confirm("开始新的额度周期？旧用量保留在历史记录中，离线机器在恢复同步前仍可能消费旧周期已发额度。")) return;
			await api(`users/${user.username}/reset`, "POST", {}); await refresh();
		});
	}
	const logs = element("audit", HTMLUListElement); logs.replaceChildren();
	for (const entry of data.audit) {
		const item = document.createElement("li"); item.textContent = `${date(entry.created_at)} · ${entry.action} · ${entry.target}`; logs.append(item);
	}
	if (!editing) permissionForm("");
}

loginForm.addEventListener("submit", event => {
	event.preventDefault();
	token = String(new FormData(loginForm).get("token") || "");
	void execute(async () => { await refresh(); loginForm.reset(); });
});
element("refresh", HTMLButtonElement).addEventListener("click", () => { void execute(refresh); });
element("logout", HTMLButtonElement).addEventListener("click", () => {
	token = ""; data = null; location.reload();
});
element("new-user", HTMLButtonElement).addEventListener("click", () => edit());
element("server-create", HTMLFormElement).addEventListener("submit", event => {
	event.preventDefault(); const form = element("server-create", HTMLFormElement);
	void execute(async () => {
		const result = await api<{ id: string; enrollment_token: string }>("servers", "POST", { name: new FormData(form).get("name") });
		reveal(`Server: ${result.id}\nEnrollment token (1 hour): ${result.enrollment_token}`);
		form.reset(); await refresh();
	});
});
element("vendor", HTMLFormElement).addEventListener("submit", event => {
	event.preventDefault(); const form = element("vendor", HTMLFormElement), values = new FormData(form);
	void execute(async () => {
		await api(`servers/${values.get("server")}/vendor`, "PUT", { veid: values.get("veid"), api_key: values.get("api_key") });
		form.reset(); await refresh();
	});
});
userForm.addEventListener("submit", event => {
	event.preventDefault();
	void execute(async () => {
		const name = input("username").value;
		const permissions = Array.from(element("permissions", HTMLDivElement).querySelectorAll("select"))
			.map(select => ({ server_id: select.dataset.server, nodes: Array.from(select.selectedOptions, o => o.value) }))
			.filter(p => p.nodes.length);
		const result = await api<{ subscription_path?: string }>(editing ? `users/${name}` : "users", editing ? "PUT" : "POST", {
			username: name, enabled: input("enabled").checked, quota_bytes: Math.floor(Number(input("quota").value) * 2 ** 30),
			expires_at: input("expires").value ? Date.parse(`${input("expires").value}T00:00:00+08:00`) / 1000 : 0,
			reset_day: Number(input("reset_day").value), permissions,
		});
		if (result.subscription_path) reveal(new URL(result.subscription_path, location.origin).href);
		editing = false; await refresh(); edit();
	});
});
