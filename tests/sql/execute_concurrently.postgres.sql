-- up
CREATE INDEX CONCURRENTLY index_posts_on_slug ON posts (slug);
-- down
DROP INDEX CONCURRENTLY index_posts_on_slug;
