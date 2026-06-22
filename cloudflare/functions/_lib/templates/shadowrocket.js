/**
 * Shadowrocket 订阅生成器。
 *
 * 与 Surge/QuantumultX 这类基于规则的格式不同，Shadowrocket 能原生导入 base64
 * 编码的分享链接列表，并支持 subflow 输出的全部协议（Reality、VLESS、VMess、
 * Shadowsocks、Trojan、TUIC、AnyTLS）。
 *
 * 流量配额与到期时间通过 `Subscription-Userinfo` HTTP 响应头传递（在编排层设置），
 * Shadowrocket 会将其渲染为原生的、自动格式化（GiB/MiB/KiB）的流量表并附带到期日期——
 * 因此本生成器只输出 URI 列表。规则由客户端本地配置，或通过独立的远程配置提供。
 */

import { CONTENT_TYPE } from "../constants.js";
import { base64NoWrap, buildLink } from "../links.js";

export function generateShadowrocket(nodes) {
	const links = nodes.map(buildLink).filter(Boolean);
	const body = base64NoWrap(links.join("\n"));
	return { contentType: CONTENT_TYPE.PLAIN, body };
}
