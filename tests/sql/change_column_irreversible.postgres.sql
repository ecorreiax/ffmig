-- up
ALTER TABLE "users" ALTER COLUMN "bio" TYPE text;
-- down
-- change_column without 'from:' is irreversible
