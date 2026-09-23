-- up
ALTER TABLE "users" RENAME COLUMN "name" TO "full_name";
-- down
ALTER TABLE "users" RENAME COLUMN "full_name" TO "name";
