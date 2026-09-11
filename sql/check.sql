SELECT
  (SELECT COUNT(*) FROM users) AS users_n,
  (SELECT COUNT(*) FROM family_metrics) AS family_src,
  (SELECT COUNT(*) FROM join_side) AS join_n,
  (SELECT COUNT(*) FROM wide_user) AS wide_rows,
  (SELECT COUNT(*) FILTER (WHERE account_created_at IS NOT NULL) FROM wide_user) AS wide_spine_nz,
  (SELECT COUNT(*) FILTER (WHERE metric_lt <> 0) FROM wide_user) AS wide_metric_nz,
  (SELECT COUNT(*) FILTER (WHERE metric_ao <> 0) FROM wide_user) AS wide_ao_nz;
