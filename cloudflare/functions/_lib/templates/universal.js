/**
 * 通用订阅生成器。
 *
 * 输出一个 base64 编码、以换行符连接的协议分享链接列表。这是兼容性最广的格式：
 * V2RayN、NekoBox、Shadowrocket 以及大多数通用客户端都能直接导入，包括那些
 * 基于规则的格式无法表达的协议（Reality、TUIC）。
 */

import { CONTENT_TYPE } from "../constants.js";
import { base64NoWrap, buildLink } from "../links.js";

export function generateUniversal(nodes) {
	const links = nodes.map(buildLink).filter(Boolean);
	const body = base64NoWrap(links.join("\n"));
	return { contentType: CONTENT_TYPE.PLAIN, body };
}
