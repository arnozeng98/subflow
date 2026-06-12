/**
 * Subscription-Userinfo header construction.
 *
 * Modern clients (Shadowrocket, Clash Verge, Stash, sing-box…) render a traffic
 * meter and an expiry date from the standard `Subscription-Userinfo` HTTP
 * response header, formatting the byte counts themselves (GiB/MiB/KiB) and the
 * `expire` unix timestamp as a date. Emitting the quota here — instead of as a
 * literal line inside the body — is what makes that native display work.
 */

const GiB = 1024 * 1024 * 1024;

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
 * Normalize the upstream `expire_at` field to whole unix seconds.
 *
 * The upstream stores it as a string: "0" (no expiry), a unix timestamp in
 * seconds or milliseconds, or an ISO-like date. Returns 0 when there is no
 * usable expiry.
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
		// 13+ digit values are milliseconds; collapse to seconds.
		return numeric >= 1e12 ? Math.floor(numeric / 1000) : numeric;
	}
	const ms = Date.parse(value);
	return Number.isFinite(ms) && ms > 0 ? Math.floor(ms / 1000) : 0;
}

/**
 * Build a `Subscription-Userinfo` header value from the upstream usage record.
 *
 * @param {object} [usage] Usage record from the VPS payload.
 * @returns {string} The header value, or "" when no quota/expiry is configured.
 */
export function buildSubscriptionUserinfo(usage) {
	if (!usage) {
		return "";
	}
	const upload = Math.max(0, Math.floor(toNumber(usage.used_up_bytes, usage.upload)));
	const download = Math.max(0, Math.floor(toNumber(usage.used_down_bytes, usage.download)));
	const quotaBytes = Math.floor(toNumber(usage.quota_bytes, usage.total_bytes, usage.total));
	const quotaFromGiB = Math.floor(toNumber(usage.quota_gb) * GiB);
	const manualAdded = Math.floor(toNumber(usage.manual_added_bytes));
	const total = Math.max(quotaBytes, quotaFromGiB + manualAdded);
	const expire = parseExpireSeconds(usage.expire_at ?? usage.expires_at ?? usage.expire);

	// Without a quota or an expiry there is nothing meaningful to display.
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
