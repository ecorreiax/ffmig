-- up
CREATE TABLE "users_profile" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "name" varchar,
  "email" varchar(255) NOT NULL,
  "role" integer DEFAULT 0 NOT NULL,
  "active" boolean DEFAULT true,
  "balance" numeric(10, 2) DEFAULT 0,
  "settings" jsonb DEFAULT '{}',
  "confirmed_at" timestamp(6) DEFAULT CURRENT_TIMESTAMP,
  "created_at" timestamp(6) NOT NULL,
  "updated_at" timestamp(6) NOT NULL
);
CREATE UNIQUE INDEX "index_users_profile_on_email" ON "users_profile" ("email");
-- down
DROP INDEX "index_users_profile_on_email";
DROP TABLE "users_profile";
