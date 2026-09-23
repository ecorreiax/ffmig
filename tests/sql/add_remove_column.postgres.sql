-- up
ALTER TABLE "users" ADD COLUMN "role" integer DEFAULT 0 NOT NULL;
ALTER TABLE "users" DROP COLUMN "bio";
-- down
ALTER TABLE "users" ADD COLUMN "bio" text;
ALTER TABLE "users" DROP COLUMN "role";
