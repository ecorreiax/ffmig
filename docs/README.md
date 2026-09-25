# FFMig documentation

These pages are also published as the FFMig website, built with
[VitePress](https://vitepress.dev). Run `make docs` for a local preview.

## Guide

- [Getting started](getting-started.md): from install to a migrated database
- [How it works](how-it-works.md): versions, tracking, transactions, rollbacks, locking
- [Running in production](production.md): timeouts, locks, CI and protecting databases

## Reference

- [The .mig language](../MIG.md): the language specification
- [Commands](commands.md): every command and flag
- [Configuration](configuration.md): `ffmig.toml`, database URLs and environment variables

## Editing these pages

- Links between pages are relative (`commands.md#migrate`), so they work
  both here and on the site. The site fails to build on a dead link.
- `index.md` is the site's landing page, and `language.md` shows
  `../MIG.md` on the site; the spec itself stays in `MIG.md`.
- A new page needs an entry in the sidebar in `.vitepress/config.mts`,
  and in the list above.
- Code blocks of `.mig` use the `mig` language, which
  `.vitepress/mig.tmLanguage.json` highlights. `make test` checks that
  each block holding a whole migration is valid.
