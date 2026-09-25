-- up
CREATE TABLE "t" (
  "id" bigserial PRIMARY KEY,
  "published_at" timestamp(6) DEFAULT CURRENT_TIMESTAMP,
  "day" date DEFAULT CURRENT_TIMESTAMP,
  "tm" time DEFAULT CURRENT_TIMESTAMP,
  "token" uuid DEFAULT gen_random_uuid()
);
-- down
DROP TABLE "t";
