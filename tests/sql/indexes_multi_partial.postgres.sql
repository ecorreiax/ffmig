-- up
CREATE INDEX "index_events_on_user_id_and_created_at" ON "events" ("user_id", "created_at");
CREATE UNIQUE INDEX "index_users_on_org_id_and_email" ON "users" ("org_id", "email") WHERE deleted_at IS NULL;
DROP INDEX "users_a_b";
-- down
CREATE INDEX "users_a_b" ON "users" ("a", "b");
DROP INDEX "index_users_on_org_id_and_email";
DROP INDEX "index_events_on_user_id_and_created_at";
