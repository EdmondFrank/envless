import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  site: "https://biliboss.github.io",
  base: "/envless",
  integrations: [
    starlight({
      title: "envless",
      description: "agent-first secrets · zero .env · zero servers",
      social: { github: "https://github.com/biliboss/envless" },
      sidebar: [
        {
          label: "Getting Started",
          items: [
            { label: "Install", slug: "getting-started/install" },
            { label: "Quickstart", slug: "getting-started/quickstart" },
          ],
        },
        {
          label: "Concepts",
          items: [
            { label: "The .env problem", slug: "concepts/the-dot-env-problem" },
          ],
        },
      ],
      customCss: ["./src/styles/custom.css"],
    }),
  ],
});
