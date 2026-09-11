SELECT
  (SELECT COUNT(*) FROM users) AS users_n,
  (SELECT COUNT(*) FROM family_a) AS family_a_src,
  (SELECT COUNT(*) FROM family_b) AS family_b_src,
  (SELECT COUNT(*) FROM wide_user) AS wide_rows,
  (SELECT COUNT(*) FILTER (WHERE account_created_at IS NOT NULL) FROM wide_user) AS wide_spine_nz,
  (SELECT COUNT(*) FILTER (WHERE metric_a <> 0) FROM wide_user) AS wide_a_nz,
  (SELECT COUNT(*) FILTER (WHERE metric_b <> 0) FROM wide_user) AS wide_b_nz;
