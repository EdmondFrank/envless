// Minimal rehype plugin that turns ```mermaid fenced blocks into
// <pre class="mermaid">…</pre> so the client-side mermaid script can
// render them. Avoids the playwright/headless-chrome dependency that
// the upstream `rehype-mermaid` package pulls in.
import { visit } from "unist-util-visit";

export default function rehypePreMermaid() {
  return (tree) => {
    visit(tree, "element", (node, index, parent) => {
      if (node.tagName !== "code") return;
      const cls = node.properties?.className;
      const classes = Array.isArray(cls) ? cls : cls ? [cls] : [];
      if (!classes.includes("language-mermaid")) return;

      // Concatenate text children to a single source string.
      const source = (node.children ?? [])
        .filter((c) => c.type === "text")
        .map((c) => c.value)
        .join("");

      const pre = {
        type: "element",
        tagName: "pre",
        properties: { className: ["mermaid"], "data-mermaid": "" },
        children: [{ type: "text", value: source }],
      };

      // If the parent is a <pre> (typical markdown rendering), replace the pre.
      if (parent && parent.type === "element" && parent.tagName === "pre") {
        const grand = parent;
        // Replace parent <pre> in its grand parent.
        // We'll signal a transform on the parent itself by mutating it.
        grand.tagName = "pre";
        grand.properties = pre.properties;
        grand.children = pre.children;
      } else if (parent && Array.isArray(parent.children)) {
        parent.children[index] = pre;
      }
    });
  };
}
