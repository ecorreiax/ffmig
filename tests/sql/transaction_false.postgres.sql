-- up
CREATE UNIQUE INDEX "index_posts_on_slug" ON "posts" ("slug");
-- down
DROP INDEX "index_posts_on_slug";
