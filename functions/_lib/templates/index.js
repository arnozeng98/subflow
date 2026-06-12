/**
 * Format dispatcher.
 *
 * Maps a negotiated format to its generator, fetching an optional operator
 * template override (cached via the Cache API) for the formats that support one.
 * Generators always return a complete config; the override only customizes the
 * skeleton, never gates correctness.
 */

import { FORMAT } from "../constants.js";
import { fetchTemplate } from "./fetcher.js";
import { generateClash } from "./clash.js";
import { generateSingbox } from "./singbox.js";
import { generateSurge } from "./surge.js";
import { generateQuantumultX } from "./quantumultx.js";
import { generateShadowrocket } from "./shadowrocket.js";
import { generateUniversal } from "./universal.js";

/**
 * Generate the subscription body for the negotiated format.
 *
 * @param {string} format Canonical format identifier.
 * @param {Array<object>} nodes Normalized nodes.
 * @param {object} config Resolved runtime config.
 * @param {ExecutionContext} [ctx] Pages execution context (for cache writes).
 * @returns {Promise<{ contentType: string, body: string }>}
 */
export async function generate(format, nodes, config, ctx) {
	switch (format) {
		case FORMAT.CLASH: {
			const template = await fetchTemplate(
				config.templateUrls.clash,
				config.templateCacheTtlSeconds,
				ctx,
			);
			return generateClash(nodes, config, template);
		}
		case FORMAT.SINGBOX: {
			const template = await fetchTemplate(
				config.templateUrls.singbox,
				config.templateCacheTtlSeconds,
				ctx,
			);
			return generateSingbox(nodes, config, template);
		}
		case FORMAT.SURGE:
			return generateSurge(nodes, config);
		case FORMAT.QUANTUMULTX:
			return generateQuantumultX(nodes, config);
		case FORMAT.SHADOWROCKET:
			return generateShadowrocket(nodes);
		default:
			return generateUniversal(nodes);
	}
}
