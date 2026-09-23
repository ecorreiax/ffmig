-- up
DROP TABLE "users";
-- down
CREATE TABLE "users" (
  "id" bigserial PRIMARY KEY,
  "email" varchar
);
