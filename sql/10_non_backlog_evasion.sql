-- Fur enforcement — evasion in non-backlog listings from known fur sellers
--
-- Finds listings that escaped Kendrick's detection entirely:
--   1. Takes sellers already confirmed as fur sellers (in fur_backlog_high_confidence)
--   2. Looks at ALL their OTHER listings (not in the backlog)
--   3. Searches the change log for title changes that went from fur signals → neutral or faux
--
-- This surfaces listings that were never flagged because sellers changed their titles
-- before Kendrick's snapshot — the listing never had fur terms when scanned.
--
-- evasion_type definitions (same as sql/09):
--   real_to_faux    — title gained "faux"; excluded by Kendrick's has_faux_proximity
--   real_to_neutral — fur/species/real terms removed with no "faux"; invisible to Kendrick
--
-- Note: listings_change_log has 90-day retention (~June 3 2026 earliest)
-- Source tables:
--   etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence
--   etsy-data-warehouse-prod.etsy_shard.listings
--   etsy-data-warehouse-prod.etsy_shard_change_logs.listings_change_log

WITH fur_sellers AS (
  SELECT DISTINCT l.user_id AS seller_user_id
  FROM `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fb
  JOIN `etsy-data-warehouse-prod.etsy_shard.listings` l USING (listing_id)
),

non_backlog_listings AS (
  SELECT l.listing_id, l.user_id AS seller_user_id
  FROM `etsy-data-warehouse-prod.etsy_shard.listings` l
  JOIN fur_sellers fs ON l.user_id = fs.seller_user_id
  LEFT JOIN `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fb
    USING (listing_id)
  WHERE fb.listing_id IS NULL
),

title_changes AS (
  SELECT
    nbl.listing_id,
    nbl.seller_user_id,
    lcl.source_ts_us AS change_ts,
    lcl.before.title AS title_before,
    lcl.after.title  AS title_after
  FROM `etsy-data-warehouse-prod.etsy_shard_change_logs.listings_change_log` lcl
  JOIN non_backlog_listings nbl ON nbl.listing_id = lcl.before.listing_id
  WHERE lcl.source_ts_us >= '2026-01-01'
    AND lcl.before.title <> lcl.after.title
),

classified AS (
  SELECT
    listing_id,
    seller_user_id,
    FORMAT_DATE('%Y-%m', DATE(change_ts)) AS change_month,
    title_before,
    title_after,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(title_after,'')), r'\bfaux\b')
        THEN 'real_to_faux'
      WHEN NOT REGEXP_CONTAINS(LOWER(title_after), r'\b(fur|fox|mink|rabbit|raccoon|beaver|pelz|real|genuine)\b')
        AND (
          REGEXP_CONTAINS(LOWER(title_before), r'\bfur\b') OR
          REGEXP_CONTAINS(LOWER(title_before), r'\b(fox|mink|rabbit|raccoon|beaver|pelz)\b') OR
          REGEXP_CONTAINS(LOWER(title_before), r'\b(real|genuine|natural)\b')
        )
        THEN 'real_to_neutral'
      ELSE 'other_change'
    END AS evasion_type
  FROM title_changes
)

-- ============================================================
-- Summary by evasion type × month
-- ============================================================

SELECT
  evasion_type,
  change_month,
  COUNT(DISTINCT listing_id)     AS listings,
  COUNT(DISTINCT seller_user_id) AS sellers,
  COUNT(*)                       AS total_edits
FROM classified
WHERE evasion_type IN ('real_to_faux', 'real_to_neutral')
GROUP BY 1, 2
ORDER BY evasion_type, change_month;


-- ============================================================
-- Detail: all real_to_neutral cases (escaped Kendrick entirely)
-- Uncomment to inspect individual before/after titles
-- ============================================================

-- SELECT
--   listing_id,
--   seller_user_id,
--   change_month,
--   title_before,
--   title_after
-- FROM classified
-- WHERE evasion_type = 'real_to_neutral'
-- ORDER BY change_month, seller_user_id, listing_id;
