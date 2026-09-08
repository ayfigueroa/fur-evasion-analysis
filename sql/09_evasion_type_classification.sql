-- Fur enforcement — evasion type classification
--
-- Classifies each title change in fur_content_changes by evasion strategy:
--
--   real_to_faux    — title gained "faux"; Kendrick excludes these via has_faux_proximity
--                     but they may still be real fur and are actively misleading buyers
--   real_to_neutral — fur/species/real terms removed with no "faux" added;
--                     these listings vanish from Kendrick entirely
--   other_change    — title changed but did not match either pattern above
--
-- Source: etsy-data-warehouse-dev.ayfigueroa.fur_content_changes
-- Columns available: listing_id, change_num, change_timing, change_date,
--   days_relative_to_sk, title_changed, title_before, title_after,
--   desc_changed, desc_before, desc_after, first_sk_decision


-- ============================================================
-- Summary: count listings and edits per evasion_type × change_timing
-- ============================================================

SELECT
  evasion_type,
  change_timing,
  COUNT(DISTINCT listing_id) AS listings,
  COUNT(*)                   AS total_edits
FROM (
  SELECT
    listing_id,
    change_num,
    change_timing,
    title_before,
    title_after,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(COALESCE(title_after,'')), r'\bfaux\b')
        THEN 'real_to_faux'
      WHEN NOT REGEXP_CONTAINS(LOWER(COALESCE(title_after,'')), r'\b(fur|fox|mink|rabbit|raccoon|beaver|pelz|real|genuine)\b')
        AND (
          REGEXP_CONTAINS(LOWER(title_before), r'\bfur\b') OR
          REGEXP_CONTAINS(LOWER(title_before), r'\b(fox|mink|rabbit|raccoon|beaver|pelz)\b') OR
          REGEXP_CONTAINS(LOWER(title_before), r'\b(real|genuine|natural)\b')
        )
        THEN 'real_to_neutral'
      ELSE 'other_change'
    END AS evasion_type
  FROM `etsy-data-warehouse-dev.ayfigueroa.fur_content_changes`
  WHERE title_changed = TRUE
    AND title_before IS NOT NULL
    AND title_after  IS NOT NULL
)
GROUP BY 1, 2
ORDER BY evasion_type, change_timing;


-- ============================================================
-- Detail: all real_to_neutral cases — these escaped Kendrick
--
-- Logic: title_before had fur signals, title_after has NONE.
-- Sellers removed the fur terms entirely — title_after is checked
-- only for absence, never for presence of species/fur words.
-- ============================================================

SELECT
  listing_id,
  change_num,
  change_timing,
  change_date,
  days_relative_to_sk,
  title_before,
  title_after
FROM `etsy-data-warehouse-dev.ayfigueroa.fur_content_changes`
WHERE title_changed = TRUE
  AND title_before IS NOT NULL
  AND title_after  IS NOT NULL
  -- title_after must be clean — no fur, species, or authenticity words
  AND NOT REGEXP_CONTAINS(LOWER(title_after), r'\b(fur|fox|mink|rabbit|raccoon|beaver|pelz|real|genuine)\b')
  -- title_before must have had at least one fur signal
  AND (
    REGEXP_CONTAINS(LOWER(title_before), r'\bfur\b') OR
    REGEXP_CONTAINS(LOWER(title_before), r'\b(fox|mink|rabbit|raccoon|beaver|pelz)\b') OR
    REGEXP_CONTAINS(LOWER(title_before), r'\b(real|genuine|natural)\b')
  )
ORDER BY change_timing, listing_id, change_num;
