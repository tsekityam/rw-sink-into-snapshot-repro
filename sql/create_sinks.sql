-- Spine first (may forward DELETE), then force-append-only family sink.
-- Matches RisingWave "maintain wide table with table sinks" pattern.

SET BACKGROUND_DDL = true;

CREATE SINK sink_users_spine
INTO wide_user (user_id, account_created_at)
AS
SELECT user_id, created_at AS account_created_at
FROM users;

CREATE SINK sink_family_metrics
INTO wide_user (user_id, metric_lt)
AS
SELECT user_id, metric_lt
FROM family_metrics
WITH (
  type = 'append-only',
  force_append_only = 'true'
);
