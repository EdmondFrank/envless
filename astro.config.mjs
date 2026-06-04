import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mdx from '@astrojs/mdx';
import rehypePreMermaid from './src/lib/rehype-pre-mermaid.mjs';

// GitHub Pages deployment lives at https://biliboss.github.io/envless/
// Override with the SITE / BASE env vars for staging or custom domains.
const SITE = process.env.SITE || 'https://biliboss.github.io';
const BASE = process.env.BASE || '/envless';

export default defineConfig({
  site: SITE,
  base: BASE,
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'envless',
      description: 'agent-first secrets · zero .env · zero servers',
      logo: {
        src: './public/logo.svg',
        replacesTitle: false,
      },
      favicon: '/favicon.svg',
      customCss: ['./src/styles/custom.css'],
      social: {
        github: 'https://github.com/biliboss/envless',
      },
      editLink: {
        baseUrl: 'https://github.com/biliboss/envless/edit/main/',
      },
      sidebar: [
        { label: 'Overview', link: '/' },
        { label: 'Quickstart', link: '/quickstart/' },
        { label: 'Architecture', link: '/architecture/' },
        { label: 'Security', link: '/security/' },
        { label: 'CLI reference', link: '/cli/' },
        { label: 'Operations', link: '/operations/' },
        { label: 'Benchmarks', link: '/benchmarks/' },
        { label: 'Why envless', link: '/why/' },
        { label: 'Changelog', link: '/changelog/' },
        { label: 'Contributing', link: '/contributing/' },
      ],
      head: [
        {
          tag: 'meta',
          attrs: { property: 'og:image', content: BASE + '/og-image.png' },
        },
        {
          tag: 'meta',
          attrs: { name: 'twitter:card', content: 'summary_large_image' },
        },
        {
          tag: 'meta',
          attrs: { name: 'twitter:image', content: BASE + '/og-image.png' },
        },
        {
          tag: 'script',
          attrs: { type: 'module' },
          content: `
            import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
            const theme = document.documentElement.dataset.theme === 'dark' ? 'dark' : 'default';
            mermaid.initialize({ startOnLoad: true, theme, securityLevel: 'loose' });
          `,
        },
      ],
    }),
    mdx(),
  ],
  markdown: {
    syntaxHighlight: 'shiki',
    rehypePlugins: [rehypePreMermaid],
  },
});
