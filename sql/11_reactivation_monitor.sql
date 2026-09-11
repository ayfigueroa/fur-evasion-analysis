-- Fur enforcement — listing reactivation monitor
--
-- Detects listings from known fur sellers that went from an inactive state
-- back to ACTIVE (state 0), with fur signals still in the title.
--
-- came_from_state: state the listing held immediately before going active
--   INACTIVE (1) — seller manually deactivated, then reactivated
--   DRAFT    (3) — draft published for the first time or re-published
--   SOLDOUT  (2) — ran out of inventory, seller renewed/restocked
--   EXPIRED  (5) — listing expired (4-month window), seller renewed ($0.20)
--
-- fur_signal_strength:
--   strong_signal   — title has species/fur term + authenticity qualifier
--                     (e.g. "Real Fox Fur", "Genuine Mink Coat")
--   species_or_fur  — title has species or fur term only
--   other           — title passed the broad fur filter but no strong pattern
--
-- Note: listings_change_log has 90-day retention (~Jun 3 2026 earliest).
--       For a daily monitoring job, replace the date filter with:
--       lcl.source_ts_us >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
--
-- Storage: etsy-data-warehouse-prod.etsy_shard_change_logs.listings_change_log
-- Compute: ~320 GB per full run


-- ============================================================
-- Summary: reactivations grouped by backlog membership,
--          prior state, and fur signal strength
-- ============================================================

WITH fur_sellers AS (
  SELECT DISTINCT l.user_id AS seller_user_id
  FROM `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fb
  JOIN `etsy-data-warehouse-prod.etsy_shard.listings` l USING (listing_id)
),

reactivated AS (
  SELECT
    lcl.before.listing_id                AS listing_id,
    l.user_id                            AS seller_user_id,
    DATE(lcl.source_ts_us)               AS reactivated_date,
    lcl.before.state                     AS state_before,
    lcl.after.title                      AS current_title,
    fb.listing_id IS NOT NULL            AS was_in_kendrick_backlog,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(lcl.after.title), r'\b(real|genuine|natural|authentic)\b')
        AND REGEXP_CONTAINS(LOWER(lcl.after.title), r'\b(fur|fox|mink|rabbit|raccoon|beaver|pelz)\b')
        THEN 'strong_signal'
      WHEN REGEXP_CONTAINS(LOWER(lcl.after.title), r'\b(fur|fox|mink|rabbit|raccoon|beaver|pelz)\b')
        THEN 'species_or_fur'
      ELSE 'other'
    END                                  AS fur_signal_strength
  FROM `etsy-data-warehouse-prod.etsy_shard_change_logs.listings_change_log` lcl
  JOIN `etsy-data-warehouse-prod.etsy_shard.listings` l
    ON l.listing_id = lcl.before.listing_id
  JOIN fur_sellers fs ON l.user_id = fs.seller_user_id
  LEFT JOIN `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fb
    ON fb.listing_id = lcl.before.listing_id
  WHERE lcl.source_ts_us >= '2026-01-01'  -- swap for INTERVAL 1 DAY in daily job
    AND lcl.before.state != 0             -- was not active
    AND lcl.after.state = 0              -- now active
    AND l.state = 0                      -- still active today
    AND REGEXP_CONTAINS(LOWER(lcl.after.title),
        r'\b(fur|fox|mink|rabbit|raccoon|beaver|pelz|genuine|real)\b')
)

SELECT
  was_in_kendrick_backlog,
  CASE state_before
    WHEN 1 THEN 'INACTIVE' WHEN 2 THEN 'SOLDOUT'
    WHEN 3 THEN 'DRAFT'    WHEN 5 THEN 'EXPIRED'
    ELSE CAST(state_before AS STRING)
  END                              AS came_from_state,
  fur_signal_strength,
  COUNT(DISTINCT listing_id)       AS listings,
  COUNT(DISTINCT seller_user_id)   AS sellers
FROM reactivated
GROUP BY 1, 2, 3
ORDER BY was_in_kendrick_backlog DESC, listings DESC;


-- ============================================================
-- Detail: individual reactivations — highest priority cases
-- (backlog listings, strong_signal, came from INACTIVE)
-- Uncomment to run
-- ============================================================

-- WITH fur_sellers AS (...),
-- reactivated AS (...),
-- listing_changes AS (
--   SELECT listing_id,
--     COUNT(*) > 0          AS had_changes,
--     COUNT(*)              AS change_count
--   FROM `etsy-data-warehouse-dev.ayfigueroa.fur_content_changes`
--   GROUP BY 1
-- )
-- SELECT r.listing_id, r.seller_user_id, r.reactivated_date,
--        r.came_from_state, r.fur_signal_strength, r.current_title,
--        COALESCE(lc.had_changes, FALSE) AS had_changes,
--        COALESCE(lc.change_count, 0)    AS change_count
-- FROM reactivated r
-- LEFT JOIN listing_changes lc USING (listing_id)
-- WHERE r.was_in_kendrick_backlog = TRUE
--   AND r.fur_signal_strength = 'strong_signal'
-- ORDER BY r.reactivated_date DESC;


-- ============================================================
-- Daily job version: escribe a tabla, usar con Scheduled Query
-- Reemplaza la seccion de Summary de arriba al productionizar
-- ============================================================

-- CREATE OR REPLACE TABLE `etsy-data-warehouse-dev.ayfigueroa.fur_reactivation_daily` AS
--
-- WITH fur_sellers AS (
--   SELECT DISTINCT l.user_id AS seller_user_id
--   FROM `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fb
--   JOIN `etsy-data-warehouse-prod.etsy_shard.listings` l USING (listing_id)
-- ),
-- listing_changes AS (
--   SELECT listing_id,
--     TRUE     AS had_changes,
--     COUNT(*) AS change_count
--   FROM `etsy-data-warehouse-dev.ayfigueroa.fur_content_changes`
--   GROUP BY 1
-- ),
-- reactivated AS (
--   SELECT
--     lcl.before.listing_id     AS listing_id,
--     l.user_id                 AS seller_user_id,
--     DATE(lcl.source_ts_us)    AS reactivated_date,
--     lcl.before.state          AS state_before,
--     lcl.after.title           AS current_title,
--     fb.listing_id IS NOT NULL AS was_in_kendrick_backlog,
--     CASE
--       WHEN REGEXP_CONTAINS(LOWER(lcl.after.title), r'\b(real|genuine|natural|authentic)\b')
--         AND REGEXP_CONTAINS(LOWER(lcl.after.title), r'\b(fur|fox|mink|rabbit|raccoon|beaver|pelz)\b')
--         THEN 'strong_signal'
--       WHEN REGEXP_CONTAINS(LOWER(lcl.after.title), r'\b(fur|fox|mink|rabbit|raccoon|beaver|pelz)\b')
--         THEN 'species_or_fur'
--       ELSE 'other'
--     END                       AS fur_signal_strength
--   FROM `etsy-data-warehouse-prod.etsy_shard_change_logs.listings_change_log` lcl
--   JOIN `etsy-data-warehouse-prod.etsy_shard.listings` l
--     ON l.listing_id = lcl.before.listing_id
--   JOIN fur_sellers fs ON l.user_id = fs.seller_user_id
--   LEFT JOIN `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fb
--     ON fb.listing_id = lcl.before.listing_id
--   WHERE lcl.source_ts_us >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
--     AND lcl.before.state != 0
--     AND lcl.after.state = 0
--     AND l.state = 0  -- still active today
--     AND REGEXP_CONTAINS(LOWER(lcl.after.title),
--         r'\b(fur|fox|mink|rabbit|raccoon|beaver|pelz|genuine|real)\b')
-- )
-- SELECT
--   r.listing_id,
--   r.seller_user_id,
--   r.reactivated_date,
--   CASE r.state_before
--     WHEN 1 THEN 'INACTIVE' WHEN 2 THEN 'SOLDOUT'
--     WHEN 3 THEN 'DRAFT'    WHEN 5 THEN 'EXPIRED'
--     ELSE CAST(r.state_before AS STRING)
--   END                                    AS came_from_state,
--   r.fur_signal_strength,
--   r.was_in_kendrick_backlog,
--   r.current_title,
--   COALESCE(lc.had_changes, FALSE)        AS had_changes,
--   COALESCE(lc.change_count, 0)           AS change_count
-- FROM reactivated r
-- LEFT JOIN listing_changes lc USING (listing_id)
-- WHERE r.fur_signal_strength IN ('strong_signal', 'species_or_fur');
