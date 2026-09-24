-- Fur enforcement — Kendrick v2.8 applied to listings reactivated since Aug 11 2026
--
-- Approach:
--   1. Pull all listings that went from any inactive state → ACTIVE since Aug 11
--   2. Restrict to those still active today (via active_listing_basics join)
--   3. Apply Kendrick v2.8 full detection logic to score each reactivated listing
--
-- This catches fur listings regardless of whether they were in the original backlog:
--   - Backlog listings that went dark and came back
--   - Non-backlog fur listings that returned under the radar
--   - Listings that changed titles BEFORE the original snapshot but are now re-live
--
-- Output columns beyond Kendrick standard:
--   reactivated_date   — earliest date after the scan start that this listing went active
--   state_before       — state immediately before the first reactivation event
--   reactivation_count — how many times it toggled inactive→active during the scan window
--
-- ── Run tracking ────────────────────────────────────────────────────────────────
-- Last run : [not yet run]
-- Next run : update lcl.source_ts_us >= '2026-08-11' to >= '[last run date]'
-- ────────────────────────────────────────────────────────────────────────────────
--
-- Compute: ~300–500 GB
-- Compute project: etsy-bq-interactive-prod
-- Storage: etsy-data-warehouse-prod

WITH

-- ============================================================
-- Step 1: All listings that went inactive → active since Aug 11
-- ============================================================
reactivated AS (
  SELECT
    lcl.before.listing_id                    AS listing_id,
    MIN(DATE(lcl.source_ts_us))              AS reactivated_date,
    ANY_VALUE(lcl.before.state)              AS state_before,
    COUNT(*)                                 AS reactivation_count
  FROM `etsy-data-warehouse-prod.etsy_shard_change_logs.listings_change_log` lcl
  WHERE lcl.source_ts_us >= '2026-08-11'
    AND lcl.before.state != 0    -- was not active
    AND lcl.after.state  = 0     -- became active
  GROUP BY 1
),

-- ============================================================
-- Step 2: Kendrick base spine — restricted to reactivated listings
--         active_listing_basics naturally excludes non-active listings
-- ============================================================
base_listings AS (
  SELECT
    alb.listing_id,
    alb.user_id,
    alb.shop_id,
    alb.title,
    l.description,   -- full description from etsy_shard (active_listing_basics truncates)
    alb.taxonomy_id,
    alb.top_category,
    alb.past_year_gms,
    alb.past_year_orders,
    alb.how_its_made_label,
    alb.price_usd,
    r.reactivated_date,
    r.state_before,
    r.reactivation_count
  FROM `etsy-data-warehouse-prod.rollups.active_listing_basics` alb
  JOIN reactivated r USING (listing_id)
  LEFT JOIN `etsy-data-warehouse-prod.etsy_shard.listings` l USING (listing_id)
  WHERE COALESCE(alb.is_digital, 0) != 1
    AND COALESCE(alb.print_on_demand.is_pod, 0) != 1
),

-- ============================================================
-- Step 3: Build normalized text fields (Kendrick with_text)
-- ============================================================
with_text AS (
  SELECT
    b.listing_id, b.user_id, b.shop_id, b.title, b.description,
    b.taxonomy_id, b.top_category, b.past_year_gms, b.past_year_orders,
    b.how_its_made_label, b.price_usd,
    b.reactivated_date, b.state_before, b.reactivation_count,
    tx.full_path,
    LOWER(REGEXP_REPLACE(COALESCE(b.title, ''), r'[^\w\s]', ' '))     AS title_text,
    LOWER(COALESCE(t.all_tags, ''))                                     AS tags_text,
    LOWER(REGEXP_REPLACE(
      CONCAT(COALESCE(b.title, ''), ' ', COALESCE(t.all_tags, '')),
      r'[^\w\s]', ' '
    ))                                                                  AS title_tags_text
  FROM base_listings b
  LEFT JOIN `etsy-data-warehouse-prod.materialized.listings_tags_concat` t
    ON b.listing_id = t.listing_id
  LEFT JOIN `etsy-data-warehouse-prod.materialized.listing_taxonomy` tx
    ON b.listing_id = tx.listing_id
),

-- ============================================================
-- Step 4: Broad pre-filter (Kendrick candidates)
-- ============================================================
candidates AS (
  SELECT *
  FROM with_text
  WHERE REGEXP_CONTAINS(title_tags_text,
      r'\b(mink|fox|beaver|rac+oons?|chinchilla|sable|marten|coyote|rabbit|lynx|bobcat|muskrats?|orylag|nutria|otter|badger|ermine|o?possums?|hamster|[ck]ara[ck]ul|astra[ck]han|broadtail|squirrel|wol(?:f|ves)|wolverines?|fitch|polecats?|persian\s+lamb|kangaroos?|tanuki|finn\s*coons?|weasels?|skunks?|marmots?|stoats?|sealskin|seal\s+fur|seal\s+pelt|pelts?|tanned|taxiderm|(?:real|genuine|natural|vintage|knitted)\s+fur|full\s+skin|let\s+out|skin\s+on\s+skin|fur\s+(?:lined|coat|jacket|stole|wrap|cape|vest|collar|hat|blanket|throw|ruff|trim|plates?)|guard\s+hairs?|blackglama|saga\s+furs?|kopenhagen\s+fur|fourrure|pelliccia|nerz\w*)\b'
    )
    AND (full_path IS NULL OR NOT REGEXP_CONTAINS(LOWER(COALESCE(full_path, '')), r'stamps_and_seals'))
),

-- ============================================================
-- Step 5: Per-term boolean flags (Kendrick matched)
-- ============================================================
matched AS (
  SELECT
    c.*,
    -- Tier 1 animals
    REGEXP_CONTAINS(title_text, r'\bmarten\b')           AS t1_marten,
    REGEXP_CONTAINS(title_text, r'\bermine\b')           AS t1_ermine,
    REGEXP_CONTAINS(title_text, r'\b[ck]ara[ck]ul\b')   AS t1_karakul,
    REGEXP_CONTAINS(title_text, r'\bastra[ck]han\b')     AS t1_astrachan,
    REGEXP_CONTAINS(title_text, r'\bbroadtail\b')        AS t1_broadtail,
    REGEXP_CONTAINS(title_text, r'\borylag\b')           AS t1_orylag,
    REGEXP_CONTAINS(title_text, r'\bnutria\b')           AS t1_nutria,
    REGEXP_CONTAINS(title_text, r'\bmuskrats?\b')        AS t1_muskrat,
    REGEXP_CONTAINS(title_text, r'\bpersian\s+lamb\b')   AS t1_persian_lamb,
    -- Tier 2 animals
    REGEXP_CONTAINS(title_text, r'\bminks?\b')           AS t2_mink,
    REGEXP_CONTAINS(title_text, r'\bbobcats?\b')         AS t2_bobcat,
    REGEXP_CONTAINS(title_text, r'\bfox(?:es)?\b')       AS t2_fox,
    REGEXP_CONTAINS(title_text, r'\brabbits?\b')         AS t2_rabbit,
    REGEXP_CONTAINS(title_text, r'\brac+oons?\b')        AS t2_raccoon,
    REGEXP_CONTAINS(title_text, r'\bwol(?:f|ves)\b')     AS t2_wolf,
    REGEXP_CONTAINS(title_text, r'\bsquirrels?\b')       AS t2_squirrel,
    REGEXP_CONTAINS(title_text, r'\bbeavers?\b')         AS t2_beaver,
    REGEXP_CONTAINS(title_text, r'\botters?\b')          AS t2_otter,
    REGEXP_CONTAINS(title_text, r'\bbadgers?\b')         AS t2_badger,
    REGEXP_CONTAINS(title_text, r'\bo?possums?\b')       AS t2_possum,
    REGEXP_CONTAINS(title_text, r'\bhamsters?\b')        AS t2_hamster,
    REGEXP_CONTAINS(title_text, r'\bcoyotes?\b')         AS t2_coyote,
    REGEXP_CONTAINS(title_text, r'\bchinchillas?\b')     AS t2_chinchilla,
    REGEXP_CONTAINS(title_text, r'\bsable\b')            AS t2_sable,
    REGEXP_CONTAINS(title_text, r'\blynx\b')             AS t2_lynx,
    REGEXP_CONTAINS(title_text, r'\bwolverines?\b')      AS t2_wolverine,
    REGEXP_CONTAINS(title_text, r'\bfitch\b')            AS t2_fitch,
    REGEXP_CONTAINS(title_text, r'\bpolecats?\b')        AS t2_polecat,
    REGEXP_CONTAINS(title_text, r'\bkangaroos?\b')       AS t2_kangaroo,
    REGEXP_CONTAINS(title_text, r'\btanuki\b')           AS t2_tanuki,
    REGEXP_CONTAINS(title_text, r'\bfinn\s*coons?\b')    AS t2_finncoon,
    REGEXP_CONTAINS(title_text, r'\bweasels?\b')         AS t2_weasel,
    REGEXP_CONTAINS(title_text, r'\bskunks?\b')          AS t2_skunk,
    REGEXP_CONTAINS(title_text, r'\bmarmots?\b')         AS t2_marmot,
    REGEXP_CONTAINS(title_text, r'\bstoats?\b')          AS t2_stoat,
    -- Seal compounds
    REGEXP_CONTAINS(title_tags_text, r'\bsealskin\b')                   AS has_sealskin,
    REGEXP_CONTAINS(title_tags_text, r'\bseal\s+(?:fur|pelt)\b')       AS has_seal_fur_pelt,
    -- Fur context signals
    REGEXP_CONTAINS(title_tags_text, r'\bfur\b')                        AS ctx_fur,
    REGEXP_CONTAINS(title_tags_text, r'\bpelts?\b')                     AS ctx_pelt,
    REGEXP_CONTAINS(title_tags_text, r'\btanned\b')                     AS ctx_tanned,
    REGEXP_CONTAINS(title_tags_text, r'\bstole\b')                      AS ctx_stole,
    REGEXP_CONTAINS(title_tags_text, r'\breal\s+fur\b')                 AS ctx_real_fur,
    REGEXP_CONTAINS(title_tags_text, r'\bgenuine\s+fur\b')              AS ctx_genuine_fur,
    REGEXP_CONTAINS(title_tags_text, r'\bnatural\s+fur\b')              AS ctx_natural_fur,
    REGEXP_CONTAINS(title_tags_text, r'\bvintage\s+fur\b')              AS ctx_vintage_fur,
    REGEXP_CONTAINS(title_tags_text, r'\bknitted\s+fur\b')              AS ctx_knitted_fur,
    REGEXP_CONTAINS(title_tags_text, r'\bfull\s+skin\b')                AS ctx_full_skin,
    REGEXP_CONTAINS(title_tags_text, r'\blet\s+out\b')                  AS ctx_let_out,
    REGEXP_CONTAINS(title_tags_text, r'\bskin\s+on\s+skin\b')          AS ctx_skin_on_skin,
    REGEXP_CONTAINS(title_tags_text, r'\bfur\s*lined\b')                AS ctx_fur_lined,
    REGEXP_CONTAINS(title_tags_text, r'\bguard\s+hairs?\b')             AS ctx_guard_hairs,
    REGEXP_CONTAINS(title_tags_text, r'\btrapp(?:ed|ing)\b')            AS ctx_trapped,
    REGEXP_CONTAINS(title_tags_text,
      r'\bfur\s+(?:coat|jacket|stole|wrap|cape|vest|collar|hat|blanket|throw|ruff|trim|cuff|muff|boa|shawl|poncho|gilet|bolero|headband|scarf|hood)\b'
    )                                                                   AS ctx_fur_garment,
    REGEXP_CONTAINS(title_tags_text, r'\bfur\s+plates?\b')             AS ctx_fur_plate,
    REGEXP_CONTAINS(title_tags_text, r'\b(?:hide|skin)\b')             AS ctx_hide_skin,
    REGEXP_CONTAINS(title_tags_text, r'\b(?:blackglama|saga\s+furs?|kopenhagen\s+fur)\b') AS ctx_auction_brand,
    REGEXP_CONTAINS(title_tags_text, r'\b(?:fourrure|pelliccia|nerz\w*)\b')               AS ctx_non_english_fur,
    REGEXP_CONTAINS(title_tags_text, r'\btaxiderm(?:y|ied|ist)?\b')    AS ctx_taxidermy,
    REGEXP_CONTAINS(title_tags_text, r'\b(?:shoulder|full\s+body)\s+mount\b') AS ctx_specific_mount,
    REGEXP_CONTAINS(title_tags_text, r'\bstudy\s+skin\b')              AS ctx_study_skin,
    REGEXP_CONTAINS(title_tags_text, r'\bjawbones?\b')                 AS ctx_jawbone,
    REGEXP_CONTAINS(title_tags_text, r'\bbone\s+specimen\b')           AS ctx_bone_specimen,
    REGEXP_CONTAINS(title_tags_text, r'\bvulture\s+culture\b')         AS ctx_vulture_culture,
    -- Negation
    REGEXP_CONTAINS(title_tags_text, r'\bangora\b')                    AS has_angora,
    REGEXP_CONTAINS(tags_text, r'\b(polyester|poly|acrylic|modacrylic|faux|synthetic|vegan)\b') AS has_tag_negation,
    REGEXP_CONTAINS(title_text, r'\b(faux|synthetic|vegan|fake|imitation|artificial)\b')        AS has_title_negation,
    REGEXP_CONTAINS(title_text,
      r'\b(?:faux|vegan|synthetic|fake|imitation|artificial)\s+(?:\w+\s+)?(?:fur|mink|fox|rabbit|chinchilla|sable|beaver|rac+oon|coyote|marten|wolf|lynx|bobcat|otter|badger|ermine|o?possum|muskrat|nutria|squirrel|hamster|[ck]ara[ck]ul|astra[ck]han|broadtail|orylag|wolverine|fitch|polecat|persian\s+lamb|kangaroo|tanuki|finn\s*coon|weasel|skunk|marmot|stoat)\b'
    )                                                                   AS has_faux_proximity,
    REGEXP_CONTAINS(LOWER(COALESCE(description, '')), r'\b(?:faux|fake|synthetic|artificial costume grade|artificial|imitation)\s+fur\b') AS has_desc_faux_fur,
    REGEXP_CONTAINS(LOWER(COALESCE(description, '')), r'\b(?:real|genuine)\s+fur\b')                             AS has_desc_real_fur,
    REGEXP_CONTAINS(title_text, r'\b(?:memorial|urn|cremation|pet\s+loss|rainbow\s+bridge|in\s+memory)\b')      AS has_pet_memorial,
    REGEXP_CONTAINS(title_tags_text, r'\b(sheep(?:skin)?|lamb(?:skin)?|shearling|toscana|reindeer|cow(?:hide)?|goat(?:skin)?|deer(?:skin)?|elk|bison|buffalo|alpaca|llama|yak|camel|ostrich|mouton|horse(?:hide)?|pig(?:skin)?|pheasants?)\b') AS has_byproduct_animal,
    REGEXP_CONTAINS(title_text, r'\b(?:stickers?|decals?|vinyl\s+decal)\b') AS has_sticker_decal,
    REGEXP_CONTAINS(title_text, r'\bmink\s+oil\b')                     AS is_mink_oil,
    REGEXP_CONTAINS(title_text, r'\b(?:doc|dr|doctor)\s+martens?\b')   AS is_doc_marten,
    REGEXP_CONTAINS(title_text, r'\babercrombie\b')                    AS is_abercrombie_fitch,
    REGEXP_CONTAINS(title_text, r'\bvan\s+pelt\b')                     AS is_van_pelt,
    REGEXP_CONTAINS(title_text, r'\bfursuit\b')                        AS has_fursuit_title
  FROM candidates c
),

-- ============================================================
-- Step 6: Compound flags (Kendrick scored)
-- ============================================================
scored AS (
  SELECT
    m.*,
    ((t1_marten AND NOT is_doc_marten) OR t1_ermine OR t1_karakul OR
     t1_astrachan OR t1_broadtail OR t1_orylag OR t1_nutria OR t1_muskrat OR
     t1_persian_lamb)                                           AS has_tier1,
    (t2_mink OR t2_bobcat OR t2_fox OR t2_rabbit OR t2_raccoon OR
     t2_wolf OR t2_squirrel OR t2_beaver OR t2_otter OR t2_badger OR
     t2_possum OR t2_hamster OR t2_coyote OR t2_chinchilla OR
     t2_sable OR t2_lynx OR t2_wolverine OR
     (t2_fitch AND NOT is_abercrombie_fitch) OR t2_polecat OR
     t2_kangaroo OR t2_tanuki OR t2_finncoon OR
     t2_weasel OR t2_skunk OR t2_marmot OR t2_stoat)           AS has_tier2,
    (ctx_fur OR ctx_pelt OR ctx_tanned OR ctx_stole OR ctx_real_fur OR
     ctx_genuine_fur OR ctx_natural_fur OR ctx_vintage_fur OR ctx_knitted_fur OR
     ctx_full_skin OR ctx_let_out OR ctx_skin_on_skin OR ctx_fur_lined OR
     ctx_guard_hairs OR ctx_trapped OR ctx_fur_garment OR ctx_fur_plate OR
     ctx_taxidermy OR ctx_specific_mount OR ctx_study_skin OR
     ctx_jawbone OR ctx_bone_specimen OR ctx_vulture_culture OR
     ctx_auction_brand OR ctx_non_english_fur OR
     (t2_kangaroo AND ctx_hide_skin))                           AS has_fur_context,
    (ctx_taxidermy OR ctx_specific_mount OR ctx_study_skin OR
     ctx_jawbone OR ctx_bone_specimen OR ctx_vulture_culture)   AS has_taxidermy_signal,
    (has_sealskin OR has_seal_fur_pelt)                         AS has_seal_compound,
    REGEXP_CONTAINS(title_text, r'\b(?:real|genuine|natural)\s+fur\b') AS has_explicit_fur_declaration,
    (REGEXP_CONTAINS(title_text, r'\breal\s+fur\b') OR
     REGEXP_CONTAINS(title_text, r'\bgenuine\s+fur\b') OR
     REGEXP_CONTAINS(title_text, r'\bnatural\s+fur\b') OR
     REGEXP_CONTAINS(title_text, r'\bvintage\s+fur\b') OR
     REGEXP_CONTAINS(title_text, r'\bknitted\s+fur\b') OR
     (REGEXP_CONTAINS(title_text, r'\bpelts?\b') AND NOT is_van_pelt) OR
     REGEXP_CONTAINS(title_text, r'\bfull\s+skin\b') OR
     REGEXP_CONTAINS(title_text, r'\bfur\s+plates?\b') OR
     REGEXP_CONTAINS(title_text, r'\b(?:blackglama|saga\s+furs?|kopenhagen\s+fur)\b') OR
     REGEXP_CONTAINS(title_text, r'\b(?:fourrure|pelliccia|nerz\w*)\b'))
                                                                AS has_strong_fur_term_in_title,
    (has_tag_negation OR has_title_negation OR (has_desc_faux_fur AND NOT has_desc_real_fur)) AS has_hard_negation
  FROM matched m
),

-- ============================================================
-- Step 7: Decision tree (Kendrick classified)
-- ============================================================
classified AS (
  SELECT
    listing_id, user_id, shop_id, title, taxonomy_id, top_category, full_path,
    past_year_gms, past_year_orders, how_its_made_label, price_usd,
    reactivated_date, state_before, reactivation_count,
    CASE
      WHEN has_angora                                                               THEN 'EXCLUDED_ANGORA'
      WHEN has_faux_proximity                                                       THEN 'EXCLUDED_FAUX_PROXIMITY'
      WHEN has_hard_negation                                                        THEN 'EXCLUDED_HARD_NEGATION'
      WHEN has_pet_memorial AND NOT has_strong_fur_term_in_title                   THEN 'EXCLUDED_PET_MEMORIAL'
      WHEN has_sticker_decal AND NOT has_strong_fur_term_in_title                  THEN 'EXCLUDED_STICKER_DECAL'
      WHEN has_fursuit_title AND NOT has_strong_fur_term_in_title
        AND NOT REGEXP_CONTAINS(tags_text, r'\breal\s*fur\b|\bgenuine\s*fur\b|\breal\s+pelt\b') THEN 'EXCLUDED_FURSUIT'
      WHEN has_taxidermy_signal AND (has_tier1 OR has_tier2) AND NOT has_strong_fur_term_in_title THEN 'TAXIDERMY_FUR_ANIMAL'
      WHEN has_explicit_fur_declaration AND NOT has_byproduct_animal               THEN 'EXPLICIT_FUR_DECLARATION'
      WHEN has_tier1 AND has_fur_context                                            THEN 'TIER1_WITH_FUR_CONTEXT'
      WHEN has_tier1                                                                THEN 'TIER1_STANDALONE'
      WHEN has_tier2 AND has_fur_context                                            THEN 'TIER2_WITH_FUR_CONTEXT'
      WHEN has_seal_compound                                                        THEN 'SEAL_COMPOUND'
      WHEN has_strong_fur_term_in_title AND NOT has_byproduct_animal               THEN 'FUR_PRODUCT_TERM_ONLY'
      ELSE 'NO_MATCH'
    END AS match_rule,
    CASE
      WHEN has_angora                                                               THEN FALSE
      WHEN has_faux_proximity                                                       THEN FALSE
      WHEN has_hard_negation                                                        THEN FALSE
      WHEN has_pet_memorial AND NOT has_strong_fur_term_in_title                   THEN FALSE
      WHEN has_sticker_decal AND NOT has_strong_fur_term_in_title                  THEN FALSE
      WHEN has_fursuit_title AND NOT has_strong_fur_term_in_title
        AND NOT REGEXP_CONTAINS(tags_text, r'\breal\s*fur\b|\bgenuine\s*fur\b|\breal\s+pelt\b') THEN FALSE
      WHEN has_taxidermy_signal AND (has_tier1 OR has_tier2) AND NOT has_strong_fur_term_in_title THEN TRUE
      WHEN has_explicit_fur_declaration AND NOT has_byproduct_animal               THEN TRUE
      WHEN has_tier1                                                                THEN TRUE
      WHEN has_tier2 AND has_fur_context                                            THEN TRUE
      WHEN has_seal_compound                                                        THEN TRUE
      WHEN has_strong_fur_term_in_title AND NOT has_byproduct_animal               THEN TRUE
      ELSE FALSE
    END AS is_fur_trade
  FROM scored
),

-- ============================================================
-- Step 8: High-confidence fur listings (confidence_band = HIGH)
-- ============================================================
final AS (
  SELECT
    listing_id,
    user_id,
    reactivated_date,
    CASE state_before
      WHEN 1 THEN 'INACTIVE' WHEN 2 THEN 'SOLDOUT'
      WHEN 3 THEN 'DRAFT'    WHEN 5 THEN 'EXPIRED'
      ELSE CAST(state_before AS STRING)
    END AS came_from_state,
    reactivation_count,
    title,
    match_rule,
    CASE
      WHEN REGEXP_CONTAINS(COALESCE(match_rule, ''), r'EXCLUDED')         THEN 'EXCLUDED'
      WHEN match_rule = 'EXPLICIT_FUR_DECLARATION'                         THEN 'HIGH'
      WHEN match_rule = 'TIER1_WITH_FUR_CONTEXT'                           THEN 'HIGH'
      WHEN match_rule = 'TIER1_STANDALONE'                                 THEN 'HIGH'
      WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'
        AND REGEXP_CONTAINS(LOWER(title), r'\b(?:fox|mink)\b')            THEN 'HIGH'
      WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'
        AND top_category IN ('clothing', 'accessories', 'bags_and_purses') THEN 'MEDIUM'
      WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'                           THEN 'REVIEW'
      WHEN match_rule = 'FUR_PRODUCT_TERM_ONLY'                            THEN 'REVIEW'
      ELSE 'OTHER'
    END AS confidence_band,
    top_category,
    full_path,
    past_year_gms,
    past_year_orders,
    is_fur_trade
  FROM classified
  WHERE is_fur_trade = TRUE
    AND match_rule NOT IN ('SEAL_COMPOUND', 'TAXIDERMY_FUR_ANIMAL')
    AND NOT (
      match_rule = 'TIER1_STANDALONE'
      AND NOT REGEXP_CONTAINS(COALESCE(full_path, ''),
        r'jackets_and_coats|hats_and_caps|raw_materials\.leather|^home_and_living\.floor_and_rugs|\.dresses|\.vests|bags_and_purses|accessories\.(?:gloves_and_sleeves|collars|scarves)|^weddings')
    )
    AND NOT REGEXP_CONTAINS(COALESCE(full_path, ''), r'^electronics_and_accessories')
    AND NOT REGEXP_CONTAINS(COALESCE(full_path, ''), r'^art_and_collectibles\.(prints|painting|photography)')
  ORDER BY
    CASE confidence_band WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'REVIEW' THEN 3 ELSE 4 END,
    past_year_gms DESC NULLS LAST
),

high_listings AS (
  SELECT * FROM final
  WHERE confidence_band = 'HIGH'
  -- AND listing_id = 1788376779
)

-- ============================================================
-- Step 9: SK coverage gap — keep only listings SK hasn't reviewed
--         since they came back live (or has never reviewed at all)
--
-- Eliminated: sk.latest_sk_review_date >= reactivated_date
--             (SK already reviewed the current live version)
-- Kept:       sk.latest_sk_review_date IS NULL (never reviewed)
--             reactivated_date > latest_sk_review_date (SK saw old inactive version)
-- ============================================================
SELECT
  f.listing_id,
  f.user_id,
  f.reactivated_date,
  sk.first_sk_review_date,
  DATE(sk.latest_sk_review_date)                                     AS latest_sk_review_date,
  sk.in_scope_policy,
  l.is_active,
  DATE_DIFF(DATE(sk.latest_sk_review_date), DATE(f.reactivated_date), DAY) AS days_from_react_to_last_review
FROM high_listings f
LEFT JOIN (
  SELECT *
  FROM `etsy-data-warehouse-prod.rollups.tns_safety_kit_integration`
  WHERE 1=1
    AND content_type = 'listing'
) sk
  ON sk.reference_id = f.listing_id
LEFT JOIN `etsy-data-warehouse-prod.listing_mart.listing_vw` l
  ON f.listing_id = l.listing_id
WHERE sk.latest_sk_review_date IS NULL
   OR f.reactivated_date > DATE(sk.latest_sk_review_date);
