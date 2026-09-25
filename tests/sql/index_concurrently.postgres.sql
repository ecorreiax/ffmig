-- up
CREATE UNIQUE INDEX CONCURRENTLY "index_posts_on_slug" ON "posts" ("slug");
DROP INDEX CONCURRENTLY "index_posts_on_title";
-- down
CREATE INDEX CONCURRENTLY "index_posts_on_title" ON "posts" ("title");
DROP INDEX CONCURRENTLY "index_posts_on_slug";
