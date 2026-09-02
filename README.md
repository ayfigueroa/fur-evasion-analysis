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

## High-priority evasion cases

### Seller 1149490363 — systematic shop-wide relabeling, still active

**Profile:** German-market seller of leather jackets, fur collars, and boots with real fox fur.

**What they did:** Between July 21 and August 20, 2026 (starting ~3 weeks before the enforcement launch), they did a mechanical find-and-replace across 107 listings — swapping every instance of `"Real Fox Fur"`, `"Genuine Fox Fur"`, `"Natural Fox Fur"` with `"Faux Fur"`. A second cleanup pass on Aug 15–16 removed remaining `"Genuine"` qualifiers they missed the first time.

**Why this matters:**
- SK never reviewed any of their listings — the relabeling happened before SK got to them, so no enforcement action was taken
- 67 listings are currently **active** on Etsy with faux fur titles
- 40 listings are inactive (deactivated, likely waiting to see if the relabeling held)
- 5 listings were removed by T&S anyway (caught by other signals)
- Several listings still contain `"Real"` or `"Genuine"` in the title even after the swap (e.g. `"Silver Faux Collar detachable Men Women Genuine Real new Manufactured in France authentic"`)
- One edit shows a typo mid-change: `"Foaux Fur"` — suggesting manual find-and-replace, not a bulk tool

**Example title changes:**
| Before | After |
|---|---|
| `Women's Leather Puffer Jacket with Real Fox Fur Hood` | `Women's Leather Puffer Jacket with Faux Fur Hood` |
| `Genuine Fox Fur Collar Black Leather Bubble Jacket` | `Genuine Faux Fur Collar Black Leather Bubble Jacket` |
| `Real Fox Fur Headband and Cuffs Set, Satin Lined` | `Faux Fur Headband and Cuffs Set, Satin Lined` |

**Listings to review:** All listings under seller 1149490363 in `ayfigueroa.fur_content_changes` — particularly the 67 currently active ones.

---

## SQL files

| File | What it does |
|---|---|
| `sql/01_fur_detection_v28.sql` | Kendrick's detection query — identifies all fur listings with confidence tiers |
| `sql/02_copy_backlog.sql` | Copies `bhagen.fur_backlog_high_confidence` to your own dev dataset |
| `sql/03_content_changes_summary.sql` | Summary: counts by change_timing bucket |
| `sql/04_content_changes_full.sql` | Full change history — every edit, with before/after content |
| `sql/05_days_from_launch_distribution.sql` | Edit timing distribution relative to SK review and Aug 11 launch |
| `sql/06_word_swap_analysis.sql` | Words removed vs added in title changes, by change_timing |
| `sql/07_seller_signals.sql` | Seller-level evasion signal table (one row per seller, 7-signal score) |
| `sql/08_seller_change_breakdown.sql` | Seller-level view with listing/edit counts per timing group and listing state |

## Tables created

All written to `etsy-data-warehouse-dev.ayfigueroa`:

- `fur_backlog_high_confidence` — copy of Brando's high-confidence listing universe (53,625 rows)
- `fur_content_changes` — full change history for all listings that modified content post-Jan 2026
- `fur_seller_signals` — seller-level evasion signals (7,212 sellers, evasion_signal_count 0–7)
- `fur_seller_change_breakdown` — seller-level listing/edit counts by timing group + listing state

## Data sources

| Table | Description |
|---|---|
| `etsy-data-warehouse-dev.bhagen.fur_backlog_high_confidence` | High-confidence fur listings (expires ~Sept 5 2026) |
| `etsy-data-warehouse-dev.bhagen.tns_safety_kit_integration` | SafetyKit decisions per listing |
| `etsy-data-warehouse-prod.etsy_shard_change_logs.listings_change_log` | Full listing edit history |
| `etsy-data-warehouse-prod.rollups.active_listing_basics` | Current active listings |
| `etsy-data-warehouse-prod.materialized.listings_tags_concat` | Tags per listing |
| `etsy-data-warehouse-prod.materialized.listing_taxonomy` | Taxonomy/category per listing |
