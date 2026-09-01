-- Fur enforcement — content change timing distribution
--
-- Two cuts of the same data:
--   Query A: days relative to each listing's individual SK review date
--   Query B: days relative to the enforcement launch date (Aug 11 2026)
--
-- Source: etsy-data-warehouse-dev.ayfigueroa.fur_content_changes


-- ============================================================
-- Query A: days relative to each listing's SK review date
-- (excludes changed_sk_never_reviewed — no SK date to anchor to)
-- ============================================================

SELECT
  change_timing,
  CASE
    WHEN days_relative_to_sk IS NULL    THEN 'N/A (SK never reviewed)'
    WHEN days_relative_to_sk < -30      THEN '< -30 days'
    WHEN days_relative_to_sk < -14      THEN '-30 to -15 days'
    WHEN days_relative_to_sk < -7       THEN '-14 to -8 days'
    WHEN days_relative_to_sk < 0        THEN '-7 to -1 days'
    WHEN days_relative_to_sk = 0        THEN 'same day as SK'
    WHEN days_relative_to_sk <= 7       THEN '+1 to +7 days'
    WHEN days_relative_to_sk <= 14      THEN '+8 to +14 days'
    WHEN days_relative_to_sk <= 30      THEN '+15 to +30 days'
    ELSE                                     '> +30 days'
  END                                        as days_bucket,
  count(distinct listing_id)                 as listings,
  count(*)                                   as total_edits
FROM `etsy-data-warehouse-dev.ayfigueroa.fur_content_changes`
GROUP BY 1, 2
ORDER BY change_timing, min(days_relative_to_sk);


-- ============================================================
-- Query B: days relative to enforcement launch (Aug 11 2026)
-- Covers all three change_timing groups including never_reviewed
-- ============================================================

SELECT
  change_timing,
  CASE
    WHEN date_diff(change_date, DATE '2026-08-11', DAY) < -30  THEN '< -30 days before launch'
    WHEN date_diff(change_date, DATE '2026-08-11', DAY) < -14  THEN '-30 to -15 days before'
    WHEN date_diff(change_date, DATE '2026-08-11', DAY) < -7   THEN '-14 to -8 days before'
    WHEN date_diff(change_date, DATE '2026-08-11', DAY) < 0    THEN '-7 to -1 days before'
    WHEN date_diff(change_date, DATE '2026-08-11', DAY) = 0    THEN 'launch day'
    WHEN date_diff(change_date, DATE '2026-08-11', DAY) <= 7   THEN '+1 to +7 days after'
    WHEN date_diff(change_date, DATE '2026-08-11', DAY) <= 14  THEN '+8 to +14 days after'
    WHEN date_diff(change_date, DATE '2026-08-11', DAY) <= 30  THEN '+15 to +30 days after'
    ELSE                                                             '> +30 days after'
  END                                                               as days_from_launch,
  count(distinct listing_id)                                        as listings,
  count(*)                                                          as total_edits
FROM `etsy-data-warehouse-dev.ayfigueroa.fur_content_changes`
GROUP BY 1, 2
ORDER BY change_timing, min(date_diff(change_date, DATE '2026-08-11', DAY));
