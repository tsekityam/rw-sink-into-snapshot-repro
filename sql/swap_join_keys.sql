-- Move every joined family row onto the spare stream key in ONE statement
-- (one barrier). Dummy user_id never matches family_metrics.
--
-- On v3.0.3 (preserve_row_level_changes, no #26713): sink emits Delete then
-- Insert for the same wide PK; Delete wipes the row; Insert only writes
-- (user_id, metric_lt) so spine / force_append_only columns go NULL / 0.
-- On v3.1.0-rc.1: those same-key Deletes are dropped; other columns stay.

SET RW_IMPLICIT_FLUSH = true;

UPDATE join_side
SET user_id = CASE
  WHEN slot = 'active' THEN 'zzzzzzzz-ffff-4ccc-8ddd-000000000000'
  WHEN slot = 'spare' THEN owner_user_id
  ELSE user_id
END;

FLUSH;
