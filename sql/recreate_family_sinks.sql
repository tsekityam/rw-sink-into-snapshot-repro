-- Recreate family sinks only (spine stays). Production still underfilled
-- after drop + create / full_refresh of the family sinks.

SET RW_IMPLICIT_FLUSH TO true;
SET BACKGROUND_DDL = true;
SET STREAMING_PARALLELISM = 4;

DROP SINK IF EXISTS sink_family_b;
DROP SINK IF EXISTS sink_family_a;

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
