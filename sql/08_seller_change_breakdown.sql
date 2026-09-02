-- Fur enforcement — seller change breakdown by timing group and listing state
--
-- One row per seller. Shows listing and edit counts for each change_timing
-- group (never_sk / before_sk / after_sk), with active vs not-active split
-- per group using the correct listing state from etsy_shard.listings
-- (state 0 = ACTIVE, 1 = INACTIVE, 2 = SOLDOUT, 3 = DRAFT, 4 = REMOVED, 5 = EXPIRED).
--
-- Note: uses pre-aggregation on both sides before joining to avoid the
-- seller_user_id cross-product bug (seller_lookup × changes fan-out).

WITH seller_lookup AS (
  SELECT l.listing_id, l.user_id AS seller_user_id, l.state
  FROM `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fb
  JOIN `etsy-data-warehouse-prod.etsy_shard.listings` l USING (listing_id)
),

changes AS (
  SELECT
    sl.seller_user_id,
    fc.listing_id,
    fc.change_num,
    fc.change_timing,
    sl.state
  FROM `etsy-data-warehouse-dev.ayfigueroa.fur_content_changes` fc
  JOIN seller_lookup sl USING (listing_id)
),

seller_totals AS (
  SELECT
    seller_user_id,
    COUNT(DISTINCT listing_id) AS total_fur_listings
  FROM seller_lookup
  GROUP BY seller_user_id
),

seller_changes AS (
  SELECT
    seller_user_id,
    COUNT(DISTINCT listing_id)                                                            AS listings_with_changes,

    COUNT(DISTINCT CASE WHEN change_timing = 'changed_sk_never_reviewed'
          THEN listing_id END)                                                            AS listings_never_sk,
    COUNTIF(change_timing = 'changed_sk_never_reviewed')                                 AS edits_never_sk,
    COUNT(DISTINCT CASE WHEN change_timing = 'changed_sk_never_reviewed' AND state = 0
          THEN listing_id END)                                                            AS active_never_sk,
    COUNT(DISTINCT CASE WHEN change_timing = 'changed_sk_never_reviewed' AND state != 0
          THEN listing_id END)                                                            AS not_active_never_sk,

    COUNT(DISTINCT CASE WHEN change_timing = 'changed_before_sk'
          THEN listing_id END)                                                            AS listings_before_sk,
    COUNTIF(change_timing = 'changed_before_sk')                                         AS edits_before_sk,
    COUNT(DISTINCT CASE WHEN change_timing = 'changed_before_sk' AND state = 0
          THEN listing_id END)                                                            AS active_before_sk,
    COUNT(DISTINCT CASE WHEN change_timing = 'changed_before_sk' AND state != 0
          THEN listing_id END)                                                            AS not_active_before_sk,

    COUNT(DISTINCT CASE WHEN change_timing = 'changed_after_sk'
          THEN listing_id END)                                                            AS listings_after_sk,
    COUNTIF(change_timing = 'changed_after_sk')                                          AS edits_after_sk,
    COUNT(DISTINCT CASE WHEN change_timing = 'changed_after_sk' AND state = 0
          THEN listing_id END)                                                            AS active_after_sk,
    COUNT(DISTINCT CASE WHEN change_timing = 'changed_after_sk' AND state != 0
          THEN listing_id END)                                                            AS not_active_after_sk,

    MAX(change_num)                                                                       AS max_edits_one_listing
  FROM changes
  GROUP BY seller_user_id
)

SELECT
  st.seller_user_id,
  st.total_fur_listings,
  sc.listings_with_changes,
  ROUND(SAFE_DIVIDE(sc.listings_with_changes, st.total_fur_listings) * 100, 1) AS pct_changed,
  sc.listings_never_sk,    sc.edits_never_sk,    sc.active_never_sk,    sc.not_active_never_sk,
  sc.listings_before_sk,   sc.edits_before_sk,   sc.active_before_sk,   sc.not_active_before_sk,
  sc.listings_after_sk,    sc.edits_after_sk,     sc.active_after_sk,    sc.not_active_after_sk,
  sc.max_edits_one_listing
FROM seller_totals st
JOIN seller_changes sc USING (seller_user_id)
ORDER BY sc.listings_with_changes DESC, sc.edits_never_sk DESC
