-- up
ALTER TABLE "users" ALTER COLUMN "age" TYPE bigint;
ALTER TABLE "users" ALTER COLUMN "name" TYPE varchar(255);
ALTER TABLE "products" ALTER COLUMN "price" TYPE numeric(12, 2);
-- down
ALTER TABLE "products" ALTER COLUMN "price" TYPE numeric(10, 2);
ALTER TABLE "users" ALTER COLUMN "name" TYPE varchar(100);
ALTER TABLE "users" ALTER COLUMN "age" TYPE integer;
