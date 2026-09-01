-- Fur enforcement — full content change history
--
-- Every title/description edit for listings in the high-confidence fur backlog,
-- with before/after content and timing relative to SK's first review.
--
-- change_timing buckets (same as 03_content_changes_summary.sql):
--   changed_before_sk         — edit happened before SK's earliest_in_scope_date
--   changed_after_sk          — edit happened after SK reviewed it
--   changed_sk_never_reviewed — listing was edited but SK never reviewed it
--
-- days_relative_to_sk: negative = edit was before SK, positive = after SK
--
-- Output: one row per edit event (~30K+ rows across ~9,500 listings that changed)
-- Saved to: etsy-data-warehouse-dev.ayfigueroa.fur_content_changes

CREATE OR REPLACE TABLE `etsy-data-warehouse-dev.ayfigueroa.fur_content_changes` AS

with
sk_decisions as (
  select
    reference_id as listing_id,
    min(date(earliest_in_scope_date)) as first_sk_decision
  from `etsy-data-warehouse-dev.bhagen.tns_safety_kit_integration`
  where content_type = 'listing'
    and in_scope_policy = 'etsy.animal_fur_products'
  group by all
),

all_changes as (
  select
    before.listing_id,
    source_ts_us                                                    as change_ts,
    row_number() over (partition by before.listing_id
                       order by source_ts_us)                       as change_num,
    before.title <> after.title                                     as title_changed,
    before.title                                                    as title_before,
    case when before.title <> after.title then after.title end      as title_after,
    before.description <> after.description                         as desc_changed,
    case when before.description <> after.description
         then after.description end                                 as desc_after
  from `etsy-data-warehouse-prod.etsy_shard_change_logs.listings_change_log` lcl
  join `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fu
    on fu.listing_id = lcl.before.listing_id
  where source_ts_us >= '2026-01-01'
    and (before.title <> after.title or before.description <> after.description)
)

select
  ac.listing_id,
  sk.first_sk_decision,
  date(ac.change_ts)                                                as change_date,
  date_diff(date(ac.change_ts), sk.first_sk_decision, DAY)         as days_relative_to_sk,
  ac.change_num,
  ac.title_changed,
  ac.title_before,
  ac.title_after,
  ac.desc_changed,
  ac.desc_after,
  case
    when sk.first_sk_decision is null                              then 'changed_sk_never_reviewed'
    when date(ac.change_ts) < sk.first_sk_decision                 then 'changed_before_sk'
    else                                                               'changed_after_sk'
  end as change_timing

from all_changes ac
left join sk_decisions sk using (listing_id)
order by ac.listing_id, ac.change_ts
