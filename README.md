# Fur Policy Enforcement — Seller Content Evasion Analysis

## Research question

> How can we identify when sellers are adapting listing content to evade Trust & Safety detection, distinguish that behavior from legitimate listing improvement, and determine which signals predict reoffense or buyer harm?

## Background

Etsy's fur policy bans listings containing natural animal fur products. Starting July 2026, the T&S team began enforcing this policy using a combination of:
- **Kendrick McDonald's detection query** (`fur_listings.sql` v2.8) — identifies ~57K active listings via heuristic text matching on title + tags
- **SafetyKit (SK)** — automated review system that processes listings and issues enforcement decisions

The backlog of ~53,625 high-confidence listings is tracked in `etsy-data-warehouse-dev.bhagen.fur_backlog_high_confidence`.

## Key findings (as of Sept 2026)

| Segment | Listings | Notes |
|---|---|---|
| No content change | 44,059 (82%) | Did not modify title or description |
| Changed **before** SK reviewed | 4,010 (7.5%) | Avg 21 days before SK — proactive evasion |
| Changed, SK **never** reviewed | 3,047 (5.7%) | Potentially evaded detection entirely |
| Changed **after** SK reviewed | 2,509 (4.7%) | Reactive evasion — avg 15 days after SK |

Notable: some listings made 60+ iterative edits, systematically testing which keywords trigger detection.

Common evasion pattern: removing explicit fur-trade terms from titles (e.g. `"Real fox tail"` → `"Upcycled tail"`, or adding `"taxidermy"` to exploit a known exclusion in the detection query).

## SQL files

| File | What it does |
|---|---|
| `sql/01_fur_detection_v28.sql` | Kendrick's detection query — identifies all fur listings with confidence tiers |
| `sql/02_copy_backlog.sql` | Copies `bhagen.fur_backlog_high_confidence` to your own dev dataset |
| `sql/03_content_changes_summary.sql` | Summary: counts by change_timing bucket |
| `sql/04_content_changes_full.sql` | Full change history — every edit, with before/after content |

## Tables created

All written to `etsy-data-warehouse-dev.ayfigueroa`:

- `fur_backlog_high_confidence` — copy of Brando's high-confidence listing universe (53,625 rows)
- `fur_content_changes` — full change history for all listings that modified content post-Jan 2026

## Data sources

| Table | Description |
|---|---|
| `etsy-data-warehouse-dev.bhagen.fur_backlog_high_confidence` | High-confidence fur listings (expires ~Sept 5 2026) |
| `etsy-data-warehouse-dev.bhagen.tns_safety_kit_integration` | SafetyKit decisions per listing |
| `etsy-data-warehouse-prod.etsy_shard_change_logs.listings_change_log` | Full listing edit history |
| `etsy-data-warehouse-prod.rollups.active_listing_basics` | Current active listings |
| `etsy-data-warehouse-prod.materialized.listings_tags_concat` | Tags per listing |
| `etsy-data-warehouse-prod.materialized.listing_taxonomy` | Taxonomy/category per listing |
