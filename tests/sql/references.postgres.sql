-- up
CREATE TABLE "sessions" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "user_id" uuid NOT NULL CONSTRAINT "fk_sessions_on_user_id" REFERENCES "users" ("id") ON DELETE CASCADE,
  "category_id" bigint CONSTRAINT "fk_sessions_on_category_id" REFERENCES "categories" ("id"),
  "device_id" bigint CONSTRAINT "fk_sessions_on_device_id" REFERENCES "devices" ("id"),
  "address_id" bigint,
  "key_id" bigint CONSTRAINT "fk_sessions_on_key_id" REFERENCES "keys" ("id") ON DELETE SET NULL,
  "author_id" bigint CONSTRAINT "fk_sessions_on_author_id" REFERENCES "users" ("id") ON DELETE RESTRICT,
  "ip_address" varchar
);
CREATE INDEX "index_sessions_on_user_id" ON "sessions" ("user_id");
CREATE INDEX "index_sessions_on_category_id" ON "sessions" ("category_id");
CREATE UNIQUE INDEX "index_sessions_on_device_id" ON "sessions" ("device_id");
CREATE INDEX "index_sessions_on_address_id" ON "sessions" ("address_id");
CREATE INDEX "index_sessions_on_author_id" ON "sessions" ("author_id");
-- down
DROP TABLE "sessions";
