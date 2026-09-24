-- up
ALTER TABLE "posts" RENAME TO "articles";
DO $$
DECLARE
  t regclass := quote_ident('articles')::regclass;
  r record;
BEGIN
  FOR r IN
    SELECT format('ALTER INDEX %s RENAME', c.oid::regclass) AS rename_sql, c.relname AS old_name,
      CASE WHEN starts_with(c.relname, 'index_posts_on_')
      THEN 'index_articles_on_' || substr(c.relname, char_length('index_posts_on_') + 1)
      ELSE 'articles_pkey' END AS new_name
    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    WHERE i.indrelid = t
      AND (starts_with(c.relname, 'index_posts_on_') OR i.indisprimary AND c.relname = 'posts_pkey')
    UNION ALL
    SELECT format('ALTER TABLE %s RENAME CONSTRAINT %I', t, conname), conname,
      'fk_articles_on_' || substr(conname, char_length('fk_posts_on_') + 1)
    FROM pg_constraint
    WHERE conrelid = t AND contype = 'f' AND starts_with(conname, 'fk_posts_on_')
    UNION ALL
    SELECT format('ALTER SEQUENCE %s RENAME', s.oid::regclass), s.relname, 'articles_id_seq'
    FROM pg_depend d JOIN pg_class s ON s.oid = d.objid AND d.classid = 'pg_class'::regclass
    WHERE d.refobjid = t AND s.relkind = 'S' AND s.relname = 'posts_id_seq'
  LOOP
    IF octet_length(r.new_name) > current_setting('max_identifier_length')::int THEN
      RAISE EXCEPTION 'cannot rename % to %: longer than % bytes',
        r.old_name, r.new_name, current_setting('max_identifier_length');
    END IF;
    EXECUTE r.rename_sql || format(' TO %I', r.new_name);
  END LOOP;
END
$$;
-- down
ALTER TABLE "articles" RENAME TO "posts";
DO $$
DECLARE
  t regclass := quote_ident('posts')::regclass;
  r record;
BEGIN
  FOR r IN
    SELECT format('ALTER INDEX %s RENAME', c.oid::regclass) AS rename_sql, c.relname AS old_name,
      CASE WHEN starts_with(c.relname, 'index_articles_on_')
      THEN 'index_posts_on_' || substr(c.relname, char_length('index_articles_on_') + 1)
      ELSE 'posts_pkey' END AS new_name
    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    WHERE i.indrelid = t
      AND (starts_with(c.relname, 'index_articles_on_') OR i.indisprimary AND c.relname = 'articles_pkey')
    UNION ALL
    SELECT format('ALTER TABLE %s RENAME CONSTRAINT %I', t, conname), conname,
      'fk_posts_on_' || substr(conname, char_length('fk_articles_on_') + 1)
    FROM pg_constraint
    WHERE conrelid = t AND contype = 'f' AND starts_with(conname, 'fk_articles_on_')
    UNION ALL
    SELECT format('ALTER SEQUENCE %s RENAME', s.oid::regclass), s.relname, 'posts_id_seq'
    FROM pg_depend d JOIN pg_class s ON s.oid = d.objid AND d.classid = 'pg_class'::regclass
    WHERE d.refobjid = t AND s.relkind = 'S' AND s.relname = 'articles_id_seq'
  LOOP
    IF octet_length(r.new_name) > current_setting('max_identifier_length')::int THEN
      RAISE EXCEPTION 'cannot rename % to %: longer than % bytes',
        r.old_name, r.new_name, current_setting('max_identifier_length');
    END IF;
    EXECUTE r.rename_sql || format(' TO %I', r.new_name);
  END LOOP;
END
$$;
