import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import mdx from "@astrojs/mdx";
import rehypePreMermaid from "./src/lib/rehype-pre-mermaid.mjs";

export default defineConfig({
  site: "https://biliboss.github.io",
  base: "/envless",
  markdown: {
    syntaxHighlight: "shiki",
    rehypePlugins: [rehypePreMermaid],
  },
  integrations: [
    starlight({
      title: "envless",
      description: "agent-first secrets · zero .env · zero servers",
      logo: {
        src: "./public/logo.svg",
        replacesTitle: false,
      },
      favicon: "/favicon.svg",
      social: { github: "https://github.com/biliboss/envless" },
      head: [
        {
          tag: "meta",
          attrs: { property: "og:image", content: "/envless/og-image.png" },
        },
        {
          tag: "meta",
          attrs: { name: "twitter:card", content: "summary_large_image" },
        },
        {
          tag: "meta",
          attrs: { name: "twitter:image", content: "/envless/og-image.png" },
        },
        {
          tag: "script",
          attrs: { type: "module" },
          content: `
            import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
            const theme = document.documentElement.dataset.theme === 'dark' ? 'dark' : 'default';
            mermaid.initialize({ startOnLoad: true, theme, securityLevel: 'loose' });
          `,
        },
      ],
      sidebar: [
        {
          label: "Getting Started",
          items: [
            { label: "Install", slug: "getting-started/install" },
            { label: "Quickstart", slug: "getting-started/quickstart" },
          ],
        },
        {
          label: "Why envless",
          items: [
            { label: "Positioning", slug: "why/positioning" },
            { label: "Comparison", slug: "why/comparison" },
            { label: "When NOT to use", slug: "why/when-not" },
            { label: "License & governance", slug: "why/license" },
            { label: "Roadmap", slug: "why/roadmap" },
          ],
        },
        {
          label: "Concepts",
          items: [
            { label: "The .env problem", slug: "concepts/the-dot-env-problem" },
            { label: "Architecture", slug: "concepts/architecture" },
            { label: "Lifecycle of a secret", slug: "concepts/lifecycle" },
          ],
        },
        {
          label: "Security",
          items: [
            { label: "Threat model", slug: "security/threat-model" },
            { label: "Cryptography (age + sops)", slug: "security/cryptography" },
            { label: "Key rotation", slug: "security/rotation" },
            { label: "Audit & supply chain", slug: "security/audit" },
          ],
        },
        {
          label: "Operations",
          items: [
            { label: "Team onboarding", slug: "operations/onboarding" },
            { label: "Recipient management", slug: "operations/recipients" },
            { label: "Disaster recovery", slug: "operations/disaster-recovery" },
            { label: "CI/CD integration", slug: "operations/cicd" },
          ],
        },
        {
          label: "Reference",
          items: [
            { label: "CLI commands", slug: "reference/cli" },
            { label: "File formats", slug: "reference/file-formats" },
            { label: "Exit codes", slug: "reference/exit-codes" },
            { label: "Environment variables", slug: "reference/env-vars" },
            { label: "Benchmarks", slug: "reference/benchmarks" },
          ],
        },
        {
          label: "Releases",
          items: [
            { label: "Latest", slug: "releases/latest" },
            { label: "Changelog", slug: "releases/changelog" },
            { label: "All versions", slug: "releases/versions" },
          ],
        },
        {
          label: "Contributing",
          items: [
            { label: "Development setup", slug: "contributing/setup" },
            { label: "Testing", slug: "contributing/testing" },
            { label: "Release process", slug: "contributing/releases" },
          ],
        },
      ],
      customCss: ["./src/styles/custom.css"],
    }),
    mdx(),
  ],
});
