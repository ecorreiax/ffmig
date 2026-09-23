-- up
CREATE UNIQUE INDEX "index_users_on_email" ON "users" ("email");
CREATE INDEX "users_email_key" ON "users" ("email");
DROP INDEX "index_users_on_name";
DROP INDEX "users_slug_key";
-- down
CREATE UNIQUE INDEX "users_slug_key" ON "users" ("slug");
CREATE INDEX "index_users_on_name" ON "users" ("name");
DROP INDEX "users_email_key";
DROP INDEX "index_users_on_email";
