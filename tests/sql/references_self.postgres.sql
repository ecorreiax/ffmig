-- up
CREATE TABLE "comments" (
  "id" bigserial PRIMARY KEY,
  "parent_id" bigint CONSTRAINT "fk_comments_on_parent_id" REFERENCES "comments" ("id") ON DELETE CASCADE,
  "body" text
);
CREATE INDEX "index_comments_on_parent_id" ON "comments" ("parent_id");
-- down
DROP TABLE "comments";
