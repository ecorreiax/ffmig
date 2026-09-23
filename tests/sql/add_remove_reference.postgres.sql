-- up
ALTER TABLE "posts" ADD COLUMN "account_id" uuid NOT NULL CONSTRAINT "fk_posts_on_account_id" REFERENCES "accounts" ("id");
CREATE INDEX "index_posts_on_account_id" ON "posts" ("account_id");
ALTER TABLE "posts" DROP COLUMN "user_id";
-- down
ALTER TABLE "posts" ADD COLUMN "user_id" bigint CONSTRAINT "fk_posts_on_user_id" REFERENCES "users" ("id") ON DELETE CASCADE;
CREATE INDEX "index_posts_on_user_id" ON "posts" ("user_id");
ALTER TABLE "posts" DROP COLUMN "account_id";
