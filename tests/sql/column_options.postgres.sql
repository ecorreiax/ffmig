-- up
CREATE TABLE "t" (
  "id" bigserial PRIMARY KEY,
  "code" varchar(10),
  "price" numeric(8),
  "total" numeric(10, 2),
  "role" integer NOT NULL,
  "bio" text DEFAULT NULL
);
-- down
DROP TABLE "t";
