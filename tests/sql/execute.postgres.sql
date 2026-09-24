-- up
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE VIEW active_users AS
  SELECT * FROM users
  WHERE deleted_at IS NULL -- soft-deleted rows stay out
;
UPDATE users SET email = lower(email);
UPDATE users SET name = 'it''s me' WHERE name = '';
-- down
DROP VIEW active_users;
