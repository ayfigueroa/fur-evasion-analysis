-- Copy Brando's high-confidence fur backlog to your own dev dataset.
-- Original expires ~Sept 5 2026. Run once to preserve it.
--
-- Source:  etsy-data-warehouse-dev.bhagen.fur_backlog_high_confidence
-- Output:  etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence
--
-- 53,625 rows | single column: listing_id (INTEGER)

CREATE OR REPLACE TABLE `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence`
AS SELECT * FROM `etsy-data-warehouse-dev.bhagen.fur_backlog_high_confidence`
