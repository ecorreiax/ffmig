-- up
ALTER TABLE "posts" ADD CONSTRAINT "fk_posts_on_author_id" FOREIGN KEY ("author_id") REFERENCES "users" ("id") ON DELETE CASCADE;
ALTER TABLE "posts" ADD CONSTRAINT "posts_parent_fkey" FOREIGN KEY ("parent_id") REFERENCES "posts" ("id");
ALTER TABLE "posts" DROP CONSTRAINT "fk_posts_on_editor_id";
-- down
ALTER TABLE "posts" ADD CONSTRAINT "fk_posts_on_editor_id" FOREIGN KEY ("editor_id") REFERENCES "users" ("id") ON DELETE SET NULL;
ALTER TABLE "posts" DROP CONSTRAINT "posts_parent_fkey";
ALTER TABLE "posts" DROP CONSTRAINT "fk_posts_on_author_id";
