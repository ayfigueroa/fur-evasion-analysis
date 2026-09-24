-- Fur enforcement — SafetyKit coverage gap on reactivated listings
--
-- Identifies reactivated fur listings that SK has NOT reviewed since they
-- came back live — i.e., the current active version has never been in scope.
--
-- Source:
--   f  — output of sql/12_reactivation_kendrick_scan.sql
--        (Kendrick v2.8 applied to all listings reactivated since Aug 11 2026)
--        Saved as: etsy-data-warehouse-dev.ldonais.sk_fur_202609
--        Replace with etsy-data-warehouse-dev.ayfigueroa.fur_reactivation_daily
--        once the daily monitoring table is created from sql/11.
--
-- Listings of interest (kept):
--   reactivated_date > latest_sk_review_date — listing came back ACTIVE after
--     SK's last review; SK saw the old (inactive) version, not the current one
--   latest_sk_review_date IS NULL — SK has never reviewed this listing at all
--
-- Listings eliminated (excluded):
--   latest_sk_review_date >= reactivated_date — SK already reviewed the live
--     version; enforcement is already in motion, no gap to surface
--
-- Compute project: etsy-bq-interactive-prod
-- Storage: etsy-data-warehouse-prod / etsy-data-warehouse-dev

SELECT
  f.listing_id,
  f.user_id,
  f.reactivated_date,
  sk.first_sk_review_date,
  DATE(sk.latest_sk_review_date)                                    AS latest_sk_review_date,
  sk.in_scope_policy,
  l.is_active,
  DATE_DIFF(
    DATE(sk.latest_sk_review_date), DATE(f.reactivated_date), DAY
  )                                                                  AS days_from_react_to_last_review
FROM `etsy-data-warehouse-dev.ldonais.sk_fur_202609` f
LEFT JOIN (
  SELECT *
  FROM `etsy-data-warehouse-prod.rollups.tns_safety_kit_integration`
  WHERE content_type = 'listing'
) sk
  ON sk.reference_id = f.listing_id
LEFT JOIN `etsy-data-warehouse-prod.listing_mart.listing_vw` l
  ON f.listing_id = l.listing_id

-- Keep only listings where SK has not reviewed the current live version
WHERE sk.latest_sk_review_date IS NULL
   OR f.reactivated_date > DATE(sk.latest_sk_review_date);
