-- Fur enforcement — word swap analysis
--
-- For every title change in fur_content_changes, identifies which words were
-- removed vs added, broken down by change_timing.
--
-- "removed" = word present in title_before but not in title_after
-- "added"   = word present in title_after but not in title_before
--
-- Stopwords (length <= 2) are excluded. Returns top 50 per direction
-- using a window function to avoid the LIMIT bias toward alphabetically
-- earlier values (i.e. "added" crowding out "removed").

WITH title_changes AS (
  SELECT
    listing_id,
    change_timing,
    SPLIT(LOWER(REGEXP_REPLACE(title_before, r'[^\w\s]', ' ')), ' ') AS words_before,
    SPLIT(LOWER(REGEXP_REPLACE(title_after,  r'[^\w\s]', ' ')), ' ') AS words_after
  FROM `etsy-data-warehouse-dev.ayfigueroa.fur_content_changes`
  WHERE title_changed = TRUE
    AND title_before IS NOT NULL
    AND title_after  IS NOT NULL
),

removed AS (
  SELECT listing_id, change_timing, word, 'removed' AS direction
  FROM title_changes, UNNEST(words_before) AS word
  WHERE word != '' AND word NOT IN UNNEST(words_after)
),

added AS (
  SELECT listing_id, change_timing, word, 'added' AS direction
  FROM title_changes, UNNEST(words_after) AS word
  WHERE word != '' AND word NOT IN UNNEST(words_before)
),

combined AS (
  SELECT direction, change_timing, word,
    COUNT(DISTINCT listing_id) AS listings_affected
  FROM (SELECT * FROM removed UNION ALL SELECT * FROM added)
  WHERE LENGTH(word) > 2
  GROUP BY 1, 2, 3
),

ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY direction ORDER BY listings_affected DESC) AS rn
  FROM combined
)

SELECT direction, change_timing, word, listings_affected
FROM ranked
WHERE rn <= 50
ORDER BY direction, listings_affected DESC
