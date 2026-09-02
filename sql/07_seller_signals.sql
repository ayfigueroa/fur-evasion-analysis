-- Fur enforcement — seller-level evasion signals
--
-- Rolls up content change behavior to the seller level.
-- One row per seller with listing counts, edit timing, keyword flags,
-- and a composite evasion_signal_count (0-7).
--
-- Requires: etsy-data-warehouse-dev.ayfigueroa.fur_content_changes (sql/04)
-- Note: seller_user_id comes from etsy_shard.listings — sellers whose
--       listings were fully removed from the platform may not appear.
--
-- Saved to: etsy-data-warehouse-dev.ayfigueroa.fur_seller_signals

CREATE OR REPLACE TABLE `etsy-data-warehouse-dev.ayfigueroa.fur_seller_signals` AS

WITH seller_lookup AS (
  SELECT l.listing_id, l.user_id AS seller_user_id
  FROM `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fb
  JOIN `etsy-data-warehouse-prod.etsy_shard.listings` l USING (listing_id)
),

changes AS (
  SELECT
    sl.seller_user_id,
    fc.listing_id,
    fc.change_num,
    fc.change_timing,
    fc.days_relative_to_sk,
    fc.title_before,
    fc.title_after,
    fc.title_changed
  FROM `etsy-data-warehouse-dev.ayfigueroa.fur_content_changes` fc
  JOIN seller_lookup sl USING (listing_id)
),

word_flags AS (
  SELECT
    seller_user_id,
    listing_id,
    LOGICAL_OR(REGEXP_CONTAINS(LOWER(title_after),  r'\bfaux\b'))        AS added_faux,
    LOGICAL_OR(REGEXP_CONTAINS(LOWER(title_after),  r'\btaxidermy\b'))   AS added_taxidermy,
    LOGICAL_OR(REGEXP_CONTAINS(LOWER(title_after),  r'\bcostume\b'))     AS added_costume,
    LOGICAL_OR(REGEXP_CONTAINS(LOWER(title_after),  r'\bsheepskin\b')
            OR REGEXP_CONTAINS(LOWER(title_after),  r'\bshearling\b'))   AS added_pivot_material,
    LOGICAL_OR(
      REGEXP_CONTAINS(LOWER(title_before), r'\bfur\b')
      AND NOT REGEXP_CONTAINS(LOWER(COALESCE(title_after, '')), r'\bfur\b')
    )                                                                     AS removed_fur,
    LOGICAL_OR(
      REGEXP_CONTAINS(LOWER(title_before), r'\b(fox|mink|rabbit|raccoon|beaver)\b')
      AND NOT REGEXP_CONTAINS(LOWER(COALESCE(title_after, '')), r'\b(fox|mink|rabbit|raccoon|beaver)\b')
    )                                                                     AS removed_species,
    LOGICAL_OR(
      REGEXP_CONTAINS(LOWER(title_before), r'\b(real|genuine)\b')
      AND NOT REGEXP_CONTAINS(LOWER(COALESCE(title_after, '')), r'\b(real|genuine)\b')
    )                                                                     AS removed_real_genuine,
    LOGICAL_OR(REGEXP_CONTAINS(LOWER(title_before), r'\bpelz\b'))        AS had_pelz
  FROM changes
  WHERE title_changed = TRUE
  GROUP BY 1, 2
)

SELECT
  sl.seller_user_id,
  COUNT(DISTINCT sl.listing_id)                                           AS total_fur_listings,
  COUNT(DISTINCT c.listing_id)                                            AS listings_with_changes,
  SAFE_DIVIDE(
    COUNT(DISTINCT c.listing_id),
    COUNT(DISTINCT sl.listing_id)
  )                                                                       AS pct_listings_changed,
  COUNTIF(c.change_timing = 'changed_before_sk')                         AS edits_before_sk,
  COUNTIF(c.change_timing = 'changed_after_sk')                          AS edits_after_sk,
  COUNTIF(c.change_timing = 'changed_sk_never_reviewed')                 AS edits_sk_never_reviewed,
  MAX(c.change_num)                                                       AS max_edits_on_one_listing,
  MIN(c.days_relative_to_sk)                                             AS earliest_edit_days_vs_sk,
  MAX(c.days_relative_to_sk)                                             AS latest_edit_days_vs_sk,
  LOGICAL_OR(wf.added_faux)                                              AS any_added_faux,
  LOGICAL_OR(wf.added_taxidermy)                                         AS any_added_taxidermy,
  LOGICAL_OR(wf.added_costume)                                           AS any_added_costume,
  LOGICAL_OR(wf.added_pivot_material)                                    AS any_pivoted_material,
  LOGICAL_OR(wf.removed_fur)                                             AS any_removed_fur,
  LOGICAL_OR(wf.removed_species)                                         AS any_removed_species,
  LOGICAL_OR(wf.removed_real_genuine)                                    AS any_removed_real_genuine,
  LOGICAL_OR(wf.had_pelz)                                                AS any_pelz_listings,
  (CAST(LOGICAL_OR(wf.added_faux)              AS INT64)
   + CAST(LOGICAL_OR(wf.added_taxidermy)       AS INT64)
   + CAST(LOGICAL_OR(wf.added_costume)         AS INT64)
   + CAST(LOGICAL_OR(wf.added_pivot_material)  AS INT64)
   + CAST(LOGICAL_OR(wf.removed_fur)           AS INT64)
   + CAST(LOGICAL_OR(wf.removed_species)       AS INT64)
   + CAST(LOGICAL_OR(wf.removed_real_genuine)  AS INT64)
  )                                                                       AS evasion_signal_count
FROM seller_lookup sl
LEFT JOIN changes c      ON c.seller_user_id = sl.seller_user_id
LEFT JOIN word_flags wf  ON wf.seller_user_id = sl.seller_user_id
GROUP BY sl.seller_user_id
ORDER BY evasion_signal_count DESC, listings_with_changes DESC
