-- Synthetic wide table. No proprietary schema.
-- Prod shape: PK user_id, ON CONFLICT DO UPDATE IF NOT NULL,
-- spine SINK INTO + force_append_only family SINK INTO (see create_sinks.sql).

SET RW_IMPLICIT_FLUSH TO true;

DROP SINK IF EXISTS sink_family_b;
DROP SINK IF EXISTS sink_family_a;
DROP SINK IF EXISTS sink_family_metrics;
DROP SINK IF EXISTS sink_users_spine;
DROP TABLE IF EXISTS wide_user;
DROP MATERIALIZED VIEW IF EXISTS family_b;
DROP MATERIALIZED VIEW IF EXISTS family_a;
DROP TABLE IF EXISTS events_b;
DROP TABLE IF EXISTS events_a;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
  user_id VARCHAR PRIMARY KEY,
  created_at TIMESTAMPTZ
);

-- Per-family event streams, then MVs grouped by user_id (the "source MV"
-- that production sinks from). Every user has a non-zero metric.
CREATE TABLE events_a (
  user_id VARCHAR,
  evt_id INT,
  amount NUMERIC,
  PRIMARY KEY (user_id, evt_id)
);

CREATE TABLE events_b (
  user_id VARCHAR,
  evt_id INT,
  amount NUMERIC,
  PRIMARY KEY (user_id, evt_id)
);

CREATE MATERIALIZED VIEW family_a AS
SELECT user_id, SUM(amount) AS metric_a
FROM events_a
GROUP BY user_id;

CREATE MATERIALIZED VIEW family_b AS
SELECT user_id, SUM(amount) AS metric_b
FROM events_b
GROUP BY user_id;

-- DEFAULT 0 is load-bearing for the underfill this harness shows.
-- CREATE SINK INTO fills omitted columns with the table default (not
-- SQL NULL). `0` is not NULL, so DO UPDATE IF NOT NULL overwrites
-- columns written by other sinks. A probe without DEFAULT filled
-- both families on v3.0.2.
CREATE TABLE wide_user (
  user_id VARCHAR PRIMARY KEY,
  account_created_at TIMESTAMPTZ,
  metric_a NUMERIC DEFAULT 0,
  metric_b NUMERIC DEFAULT 0
) ON CONFLICT DO UPDATE IF NOT NULL;
