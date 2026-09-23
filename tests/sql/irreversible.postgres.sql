-- up
DROP INDEX "users_email_key";
DROP TABLE "users";
-- down
-- remove_index without a column is irreversible
