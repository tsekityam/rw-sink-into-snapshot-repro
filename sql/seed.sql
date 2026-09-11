-- Synthetic wide-table + family MV + join-side for SINK INTO / #26713.
-- No proprietary schema. Keys are text UUIDs shaped like production.
--
-- Models:
--   * wide PK = user_id, ON CONFLICT DO UPDATE IF NOT NULL
--     (auto-enables preserve_row_level_changes on table sinks)
--   * spine sink (stream key = user_id = table PK)
--   * force_append_only family sink (production-shaped)
--   * join upsert family sink whose stream key includes join_side.join_id
--     and therefore differs from the target PK (the #26713 path)

DROP SINK IF EXISTS sink_family_join;
DROP SINK IF EXISTS sink_family_append;
DROP SINK IF EXISTS sink_family_metrics;
DROP SINK IF EXISTS sink_users_spine;
DROP TABLE IF EXISTS wide_user;
DROP MATERIALIZED VIEW IF EXISTS family_metrics;
DROP TABLE IF EXISTS join_side;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
  user_id VARCHAR PRIMARY KEY,
  created_at TIMESTAMPTZ
);

-- Extra join table so a family sink's stream key is (user_id, join_id),
-- not the wide table PK. Each user has an "active" match and a "spare"
-- dummy row; swapping them in one UPDATE moves the join row to a new
-- stream key inside one barrier (see RisingWave e2e
-- stream_key_mismatch_partial_update.slt from PR #26713).
CREATE TABLE join_side (
  join_id VARCHAR PRIMARY KEY,
  user_id VARCHAR,
  owner_user_id VARCHAR,
  slot VARCHAR
);

CREATE MATERIALIZED VIEW family_metrics AS
SELECT
  user_id,
  -- every user has a non-zero metric so FILTER (<> 0) == row count
  (1000 + length(user_id))::numeric AS metric_lt
FROM users;

CREATE TABLE wide_user (
  user_id VARCHAR PRIMARY KEY,
  account_created_at TIMESTAMPTZ,
  metric_lt NUMERIC DEFAULT 0,
  metric_ao NUMERIC DEFAULT 0
) ON CONFLICT DO UPDATE IF NOT NULL;
