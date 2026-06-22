/**
 * 格式分发器（dispatcher）。
 *
 * 将协商得出的输出格式映射到对应的生成器，并为支持模板的格式获取可选的
 * 运营方自定义模板覆盖项（通过 Cache API 缓存）。生成器始终返回一份完整的
 * 配置；覆盖项仅用于定制骨架，不会影响配置的正确性。
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
 * 为协商得出的输出格式生成订阅内容。
 *
 * @param {string} format 规范化的格式标识符。
 * @param {Array<object>} nodes 已归一化的节点列表。
 * @param {object} config 解析后的运行时配置。
 * @param {ExecutionContext} [ctx] Pages 执行上下文（用于缓存写入）。
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
