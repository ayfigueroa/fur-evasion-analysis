-- Fur enforcement — content change timing summary
--
-- For each listing in the high-confidence fur backlog, classifies whether
-- the seller changed title/description before SK reviewed it, after, or not at all.
--
-- change_timing buckets:
--   no_change                 — no title/description edits found since Jan 2026
--   changed_before_sk         — first edit happened before SK's earliest_in_scope_date
--   changed_after_sk          — first edit happened after SK reviewed it
--   changed_sk_never_reviewed — listing was edited but SK never reviewed it
--
-- Output: one row per listing (53,625 total)

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

first_change as (
  select
    before.listing_id,
    min(source_ts_us)                                               as first_change_ts,
    logical_or(before.title <> after.title)                        as title_changed,
    logical_or(before.description <> after.description)            as desc_changed
  from `etsy-data-warehouse-prod.etsy_shard_change_logs.listings_change_log` lcl
  join `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fu
    on fu.listing_id = lcl.before.listing_id
  where source_ts_us >= '2026-01-01'
    and (before.title <> after.title or before.description <> after.description)
  group by all
)

select
  fu.listing_id,
  sk.first_sk_decision,
  date(fc.first_change_ts)                                          as first_change_date,
  date_diff(date(fc.first_change_ts), sk.first_sk_decision, DAY)   as days_relative_to_sk,
  fc.title_changed,
  fc.desc_changed,
  case
    when fc.first_change_ts is null                                then 'no_change'
    when sk.first_sk_decision is null                              then 'changed_sk_never_reviewed'
    when date(fc.first_change_ts) < sk.first_sk_decision           then 'changed_before_sk'
    else                                                               'changed_after_sk'
  end as change_timing

from `etsy-data-warehouse-dev.ayfigueroa.fur_backlog_high_confidence` fu
left join sk_decisions  sk using (listing_id)
left join first_change  fc using (listing_id)
