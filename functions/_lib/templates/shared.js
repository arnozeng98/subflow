/**
 * Shared helpers for the per-platform config generators.
 *
 * Keeps small cross-format concerns (proxy name collection, quoting) in one
 * place so each generator stays focused on its own file format.
 */

/** All node display names, in order. */
export function nodeNames(nodes) {
	return nodes.map((node) => node.name);
}

/** Double-quote a value for safe embedding in a YAML scalar. */
export function yamlQuote(value) {
	return `"${String(value ?? "").replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

/** Indent every line of a block by `spaces` spaces. */
export function indent(block, spaces) {
	const pad = " ".repeat(spaces);
	return block
		.split("\n")
		.map((line) => (line ? pad + line : line))
		.join("\n");
}
