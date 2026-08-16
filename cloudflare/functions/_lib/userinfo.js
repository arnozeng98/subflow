/**
 * Subscription-Userinfo 响应头的构造。
 *
 * 现代客户端（Shadowrocket、Clash Verge、Stash、sing-box 等）会根据标准的
 * `Subscription-Userinfo` HTTP 响应头渲染出流量计量表与到期日期，它们会自行
 * 将字节数格式化（GiB/MiB/KiB），并把 `expire` 这个 unix 时间戳呈现为日期。在这里
 * 输出配额信息——而不是作为身体内的一行文字——正是让这种原生显示生效的关键。
 */

const GiB = 1024 * 1024 * 1024;

// 上游把 `quota_gb` 存为单向数值，而它的 v2ray_api 计数器同样只报告约一半的真实
// 双向流量。将配额与使用量计数器按同一系数缩放，能让客户端的计量表保持一致：
// 它会显示真实的配额（quota_gb=50 -> 100GB），且进度条恰好在上游对用户限速时填满。
const QUOTA_DISPLAY_MULTIPLIER = 2;

function toNumber(...candidates) {
	for (const value of candidates) {
		if (value == null || value === "") {
			continue;
		}
		const num = Number(value);
		if (Number.isFinite(num)) {
			return num;
		}
	}
	return 0;
}

/**
 * 将上游的 `expire_at` 字段规范化为整数的 unix 秒。
 *
 * 上游以字符串形式存储它："0"（无到期）、以秒或毫秒为单位的 unix 时间戳，
 * 或类似 ISO 的日期字符串。当没有可用的到期时间时返回 0。
 */
function parseExpireSeconds(expireAt) {
	if (expireAt == null) {
		return 0;
	}
	const value = String(expireAt).trim();
	if (!value || value === "0") {
		return 0;
	}
	if (/^\d+$/.test(value)) {
		const numeric = Number(value);
		if (!Number.isFinite(numeric) || numeric <= 0) {
			return 0;
		}
		// 13 位及以上的数值是毫秒；将其折算为秒。
		return numeric >= 1e12 ? Math.floor(numeric / 1000) : numeric;
	}
	const ms = Date.parse(value);
	return Number.isFinite(ms) && ms > 0 ? Math.floor(ms / 1000) : 0;
}

/**
 * 从上游的使用量记录构建一个 `Subscription-Userinfo` 响应头的值。
 *
 * @param {object} [usage] VPS 负载中的使用量记录。
 * @returns {string} 响应头的值；未配置配额或到期时间时为 ""。
 */
export function buildSubscriptionUserinfo(usage) {
	if (!usage) {
		return "";
	}
	// 使用量 = 上行 + 下行。客户端会自行将这两个响应头字段相加。
	// 使用量计数器与配额都按同一系数缩放，以保持计量表准确：
	// 进度条恰好在用户被限速时填满。
	const upload = Math.max(0, Math.floor(toNumber(usage.used_up_bytes) * QUOTA_DISPLAY_MULTIPLIER));
	const download = Math.max(0, Math.floor(toNumber(usage.used_down_bytes) * QUOTA_DISPLAY_MULTIPLIER));
	const total = Math.max(0, Math.floor(toNumber(usage.quota_gb) * QUOTA_DISPLAY_MULTIPLIER * GiB));
	const expire = parseExpireSeconds(usage.expire_at);

	// 若既无配额也无到期，则没有任何有意义的内容可供展示。
	if (total <= 0 && expire <= 0) {
		return "";
	}

	const parts = [`upload=${upload}`, `download=${download}`];
	if (total > 0) {
		parts.push(`total=${total}`);
	}
	if (expire > 0) {
		parts.push(`expire=${expire}`);
	}
	return parts.join("; ");
}
