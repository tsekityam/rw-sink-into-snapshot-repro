-- Synthetic wide-table + family MV for SINK INTO snapshot repro.
-- No proprietary schema. Keys are text UUIDs shaped like production.

DROP SINK IF EXISTS sink_family_metrics;
DROP SINK IF EXISTS sink_users_spine;
DROP TABLE IF EXISTS wide_user;
DROP MATERIALIZED VIEW IF EXISTS family_metrics;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
  user_id VARCHAR PRIMARY KEY,
  created_at TIMESTAMPTZ
);

-- N_USERS rows injected by run-repro.sh via generate_series.
-- Placeholder comment only; inserts happen in the script.

CREATE MATERIALIZED VIEW family_metrics AS
SELECT
  user_id,
  -- every user has a non-zero metric so FILTER (<> 0) == row count
  (1000 + length(user_id))::numeric AS metric_lt
FROM users;

CREATE TABLE wide_user (
  user_id VARCHAR PRIMARY KEY,
  account_created_at TIMESTAMPTZ,
  metric_lt NUMERIC DEFAULT 0
) ON CONFLICT DO UPDATE IF NOT NULL;
