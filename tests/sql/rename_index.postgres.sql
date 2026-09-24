-- up
ALTER INDEX "index_users_on_email" RENAME TO "users_email_key";
-- down
ALTER INDEX "users_email_key" RENAME TO "index_users_on_email";
