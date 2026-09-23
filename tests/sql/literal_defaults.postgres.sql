-- up
CREATE TABLE "t" (
  "id" bigserial PRIMARY KEY,
  "s" varchar DEFAULT 'guest',
  "t" text DEFAULT 'a"b\c',
  "i" integer DEFAULT -5,
  "b" bigint DEFAULT 9223372036854775807,
  "f" double precision DEFAULT 1,
  "d" numeric DEFAULT 0,
  "active" boolean DEFAULT false,
  "day" date DEFAULT '2026-01-01',
  "at" timestamp(6) DEFAULT '2026-01-01 12:00:00',
  "tm" time DEFAULT '12:00:00',
  "u" uuid DEFAULT '00000000-0000-0000-0000-000000000000',
  "settings" jsonb DEFAULT '{}',
  "blob" bytea DEFAULT NULL
);
-- down
DROP TABLE "t";
