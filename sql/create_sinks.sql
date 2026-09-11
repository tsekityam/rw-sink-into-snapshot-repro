-- Spine first, then force-append-only family sinks (official
-- "maintain wide table with table sinks" pattern).
-- Each family sink lists only its own columns; omitted wide columns
-- take the table DEFAULT (see seed.sql).
-- BACKGROUND_DDL so we wait on rw_ddl_progress / fragment backfill
-- the same way production does after CREATE SINK.

SET RW_IMPLICIT_FLUSH TO true;
SET BACKGROUND_DDL = true;

-- Raise parallelism above the single_node default of 1. Snapshot
-- backfill races are much more likely with multiple fragments.
SET STREAMING_PARALLELISM = 4;

CREATE SINK sink_users_spine
INTO wide_user (user_id, account_created_at)
AS
SELECT user_id, created_at AS account_created_at
FROM users;

CREATE SINK sink_family_a
INTO wide_user (user_id, metric_a)
AS
SELECT user_id, metric_a
FROM family_a
WITH (
  type = 'append-only',
  force_append_only = 'true'
);

CREATE SINK sink_family_b
INTO wide_user (user_id, metric_b)
AS
SELECT user_id, metric_b
FROM family_b
WITH (
  type = 'append-only',
  force_append_only = 'true'
);
