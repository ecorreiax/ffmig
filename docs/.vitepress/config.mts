import { readFileSync } from 'node:fs'
import { defineConfig } from 'vitepress'
import mig from './mig.tmLanguage.json'

const repo = 'https://github.com/ecorreiax/ffmig'

// The version `ffmig --version` prints, for the landing page's badge.
const zon = readFileSync(new URL('../../build.zig.zon', import.meta.url), 'utf8')
const version = zon.match(/\.version = "([^"]+)"/)![1]

export default defineConfig({
  title: 'FFMig',
  description: 'Database migrations in a small, database-neutral language.',
  cleanUrls: true,
  lastUpdated: true,
  // README.md is the index for people browsing docs/ on GitHub.
  srcExclude: ['README.md'],
  head: [['link', { rel: 'icon', type: 'image/svg+xml', href: '/logo.svg' }]],
  markdown: {
    theme: { light: 'vitesse-light', dark: 'vitesse-dark' },
    // mig embeds sql for the contents of """ strings, so sql loads first.
    languages: ['sql', mig as any],
  },
  themeConfig: {
    version,
    logo: '/logo.svg',
    nav: [
      { text: 'Guide', link: '/getting-started', activeMatch: '^/(getting-started|how-it-works|production)' },
      { text: 'Reference', link: '/language', activeMatch: '^/(language|commands|configuration)' },
    ],
    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting started', link: '/getting-started' },
          { text: 'How it works', link: '/how-it-works' },
          { text: 'Running in production', link: '/production' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'The .mig language', link: '/language' },
          { text: 'Commands', link: '/commands' },
          { text: 'Configuration', link: '/configuration' },
        ],
      },
    ],
    outline: { level: [2, 3] },
    search: { provider: 'local' },
    socialLinks: [{ icon: 'github', link: repo }],
    editLink: {
      // language.md only includes MIG.md, so edits go to the spec itself.
      // The function is sent to the browser on its own, so it cannot use
      // `repo`.
      pattern: ({ filePath }) =>
        filePath === 'language.md'
          ? 'https://github.com/ecorreiax/ffmig/edit/main/MIG.md'
          : `https://github.com/ecorreiax/ffmig/edit/main/docs/${filePath}`,
      text: 'Edit this page on GitHub',
    },
    footer: {
      message: 'Released under the MIT License.',
    },
  },
})
