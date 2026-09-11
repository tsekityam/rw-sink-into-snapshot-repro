-- Spine first (stream key = PK), then force-append-only family, then
-- the join upsert whose stream key differs from the target PK.
-- Matches RisingWave "maintain wide table with table sinks" plus the
-- preserve_row_level_changes path fixed in #26713.

SET BACKGROUND_DDL = true;

-- Stream key = user_id = wide_user PK.
CREATE SINK sink_users_spine
INTO wide_user (user_id, account_created_at)
AS
SELECT user_id, created_at AS account_created_at
FROM users;

-- Production-shaped family: append-only / force_append_only.
CREATE SINK sink_family_append
INTO wide_user (user_id, metric_ao)
AS
SELECT user_id, metric_lt AS metric_ao
FROM family_metrics
WITH (
  type = 'append-only',
  force_append_only = 'true'
);

-- #26713: non-append-only sink into DO UPDATE IF NOT NULL where the
-- input stream key (join of family_metrics PK + join_side PK) is not
-- the target PK. A later UPDATE on join_side moves a row between
-- stream keys in one barrier; without the fix that arrives as
-- Delete + Insert and wipes columns written by the other sinks.
CREATE SINK sink_family_join
INTO wide_user (user_id, metric_lt)
AS
SELECT j.user_id, m.metric_lt
FROM family_metrics m
JOIN join_side j ON m.user_id = j.user_id;
