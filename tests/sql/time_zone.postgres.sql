-- up
CREATE TABLE "events" (
  "id" bigserial PRIMARY KEY,
  "at" timestamptz(6) DEFAULT CURRENT_TIMESTAMP,
  "created_at" timestamptz(6) NOT NULL,
  "updated_at" timestamptz(6) NOT NULL
);
ALTER TABLE "events" ALTER COLUMN "at" TYPE timestamp(6);
-- down
ALTER TABLE "events" ALTER COLUMN "at" TYPE timestamptz(6);
DROP TABLE "events";
