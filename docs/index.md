---
layout: home

hero:
  text: 'Migrations you can <span class="accent">read</span>.'
  tagline: Write schema changes in a small, database-neutral language. FFMig turns them into SQL, runs them safely, and works out how to undo them.
  actions:
    - theme: brand
      text: Get started
      link: /getting-started
    - theme: alt
      text: Read the language spec
      link: /language

features:
  - icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/></svg>'
    title: Reversible by default
    details: A change block derives its own rollback. Write up and down blocks, with raw SQL, only when you need them.
  - icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>'
    title: See the SQL first
    details: <code>ffmig sql</code> and <code>migrate --dry-run</code> print exactly what will run, so a deploy's SQL can be reviewed in CI.
  - icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>'
    title: Safe to run
    details: Each migration runs in a transaction with its tracking row, and a lock makes concurrent deploys apply each one exactly once.
  - icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/></svg>'
    title: Checked before anything runs
    details: Every pending file is parsed and checked first, so a typo never leaves a batch half-applied. Errors point at the line and column.
  - icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9h16M4 15h16M10 3 8 21M16 3l-2 18"/></svg>'
    title: Knows when history changes
    details: Applied files are checksummed. An edited one is flagged by <code>status</code>, and <code>migrate --strict</code> refuses to run.
  - icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m4 17 6-6-6-6"/><path d="M12 19h8"/></svg>'
    title: One native binary
    details: A small CLI written in Zig. No language runtime or ORM to install. PostgreSQL today; the language itself is database-neutral.
---

<div class="showcase">

<div class="showcase-head">
  <h2>Write it once. Review the SQL. Run it.</h2>
  <p>A migration describes the change. FFMig shows you the SQL before anything runs, and derives the rollback from the same file.</p>
</div>

<div class="code-pair">
<div class="code-card">
<div class="code-card-bar is-mig">migrations/20260923140512_create_users.mig</div>

```mig
migration CreateUsers {
  change {
    create_table :users, id: :uuid {
      string :email, null: false
      string :name, null: false
      references :team, on_delete: :cascade
      timestamps
    }

    add_index :users, :email, unique: true
  }
}
```

</div>
<div class="code-card">
<div class="code-card-bar">ffmig sql migrations/20260923140512_create_users.mig</div>

```sql
CREATE TABLE "users" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "email" varchar NOT NULL,
  "name" varchar NOT NULL,
  "team_id" bigint CONSTRAINT "fk_users_on_team_id"
    REFERENCES "teams" ("id") ON DELETE CASCADE,
  "created_at" timestamp(6) NOT NULL,
  "updated_at" timestamp(6) NOT NULL
);
CREATE INDEX "index_users_on_team_id" ON "users" ("team_id");
CREATE UNIQUE INDEX "index_users_on_email" ON "users" ("email");
```

</div>
</div>

<div class="code-card">
<div class="code-card-bar">Terminal</div>

```sh
$ ffmig migrate
Migrated migrations/20260923120000_create_teams.mig
Migrated migrations/20260923140512_create_users.mig

$ ffmig status
up    2026-09-25 01:56:24 UTC  migrations/20260923120000_create_teams.mig
up    2026-09-25 01:56:24 UTC  migrations/20260923140512_create_users.mig

$ ffmig sql --down migrations/20260923140512_create_users.mig
DROP INDEX "index_users_on_email";
DROP TABLE "users";
```

</div>

</div>
