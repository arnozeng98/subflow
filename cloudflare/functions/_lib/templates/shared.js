/**
 * 各平台配置生成器的公用辅助函数。
 *
 * 将跨格式的小型通用逻辑（节点名称收集、引号转义）集中在一处，
 * 让每个生成器都能专注于自身的文件格式。
 */

/** 按顺序返回所有节点的显示名称。 */
export function nodeNames(nodes) {
	return nodes.map((node) => node.name);
}

/** 将值加上双引号，以便安全地嵌入 YAML 标量中。 */
export function yamlQuote(value) {
	return `"${String(value ?? "").replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

/** 将代码块的每一行都缩进 `spaces` 个空格。 */
export function indent(block, spaces) {
	const pad = " ".repeat(spaces);
	return block
		.split("\n")
		.map((line) => (line ? pad + line : line))
		.join("\n");
}
