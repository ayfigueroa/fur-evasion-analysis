WITH



-- =============================================================================

-- CTE 1: base_listings

-- Active listings spine; hard-exclude digital and print-on-demand.

-- =============================================================================

base_listings AS (

  SELECT

    listing_id,

    user_id,

    shop_id,

    title,

    description,

    taxonomy_id,

    top_category,

    past_year_gms,

    past_year_orders,

    how_its_made_label,

    price_usd

  FROM `etsy-data-warehouse-prod.rollups.active_listing_basics`

  WHERE COALESCE(is_digital, 0) != 1

    AND COALESCE(print_on_demand.is_pod, 0) != 1

),



-- =============================================================================

-- CTE 2: with_text

-- Join tags + taxonomy. Build normalized text fields for matching.

-- Title + tags = primary matching surface.  Description excluded from matching

-- to eliminate false positives from incidental mentions in long text.

-- =============================================================================

with_text AS (

  SELECT

    b.listing_id,

    b.user_id,

    b.shop_id,

    b.title,

    b.taxonomy_id,

    b.top_category,

    tx.full_path,

    b.past_year_gms,

    b.past_year_orders,

    b.how_its_made_label,

    b.price_usd,



    -- Normalized title (for animal name matching — primary signal)

    LOWER(REGEXP_REPLACE(COALESCE(b.title, ''), r'[^\w\s]', ' ')) AS title_text,



    -- Normalized tags (for tag-specific negation checks)

    LOWER(COALESCE(t.all_tags, '')) AS tags_text,



    -- Combined title + tags (for fur context signals and broad negation)

    LOWER(REGEXP_REPLACE(

      CONCAT(COALESCE(b.title, ''), ' ', COALESCE(t.all_tags, '')),

      r'[^\w\s]', ' '

    )) AS title_tags_text,



    -- Description (from active_listing_basics, for targeted faux detection in matched CTE)

    b.description



  FROM base_listings b

  LEFT JOIN `etsy-data-warehouse-prod.materialized.listings_tags_concat` t

    ON b.listing_id = t.listing_id

  LEFT JOIN `etsy-data-warehouse-prod.materialized.listing_taxonomy` tx

    ON b.listing_id = tx.listing_id

),



-- =============================================================================

-- CTE 3: candidates

-- Broad pre-filter on title+tags to reduce row set before expensive regex.

-- Also excludes stamps_and_seals taxonomy (wax seal noise).

-- =============================================================================

candidates AS (

  SELECT *

  FROM with_text

  WHERE

    REGEXP_CONTAINS(title_tags_text,

      r'\b(mink|fox|beaver|rac+oons?|chinchilla|sable|marten|coyote|rabbit|lynx|bobcat|muskrats?|orylag|nutria|otter|badger|ermine|o?possums?|hamster|[ck]ara[ck]ul|astra[ck]han|broadtail|squirrel|wol(?:f|ves)|wolverines?|fitch|polecats?|persian\s+lamb|kangaroos?|tanuki|finn\s*coons?|weasels?|skunks?|marmots?|stoats?|sealskin|seal\s+fur|seal\s+pelt|pelts?|tanned|taxiderm|(?:real|genuine|natural|vintage|knitted)\s+fur|full\s+skin|let\s+out|skin\s+on\s+skin|fur\s+(?:lined|coat|jacket|stole|wrap|cape|vest|collar|hat|blanket|throw|ruff|trim|plates?)|guard\s+hairs?|blackglama|saga\s+furs?|kopenhagen\s+fur|fourrure|pelliccia|nerz\w*)\b'

    )

    -- Exclude stamps_and_seals taxonomy sub-path

    AND (

      full_path IS NULL

      OR NOT REGEXP_CONTAINS(LOWER(COALESCE(full_path, '')), r'stamps_and_seals')

    )

),



-- =============================================================================

-- CTE 4: matched

-- Compute per-term boolean flags, organized by matching tier.

-- =============================================================================

matched AS (

  SELECT

    c.*,



    -- =================================================================

    -- TIER 1 ANIMALS — low-ambiguity, standalone in title is sufficient

    -- Almost never mentioned on Etsy outside fur/trapping contexts.

    -- (mink and bobcat moved to Tier 2: mink is a common color name,

    --  bobcat is a brand/mascot)

    -- v2.1: added persian lamb; alternate spellings for karakul/astrachan

    -- =================================================================

    REGEXP_CONTAINS(title_text, r'\bmarten\b')           AS t1_marten,

    REGEXP_CONTAINS(title_text, r'\bermine\b')           AS t1_ermine,

    REGEXP_CONTAINS(title_text, r'\b[ck]ara[ck]ul\b')   AS t1_karakul,    -- karakul, caracul, etc.

    REGEXP_CONTAINS(title_text, r'\bastra[ck]han\b')     AS t1_astrachan,  -- astrachan, astrakhan

    REGEXP_CONTAINS(title_text, r'\bbroadtail\b')        AS t1_broadtail,

    REGEXP_CONTAINS(title_text, r'\borylag\b')           AS t1_orylag,

    REGEXP_CONTAINS(title_text, r'\bnutria\b')           AS t1_nutria,

    REGEXP_CONTAINS(title_text, r'\bmuskrats?\b')        AS t1_muskrat,

    REGEXP_CONTAINS(title_text, r'\bpersian\s+lamb\b')   AS t1_persian_lamb,



    -- =================================================================

    -- TIER 2 ANIMALS — high-ambiguity, require fur context co-occurrence

    -- Common in art, toys, decor, pet supplies, color names on Etsy.

    -- mink: very common as a color name ("mink brown", "mink grey")

    -- bobcat: brand name (knives), university mascot

    -- chinchilla: pet supplies

    -- sable: color name ("sable german shepherd")

    -- wolverine: X-Men/Marvel, Wolverine boot brand

    -- fitch: "Abercrombie & Fitch" (needs fur context to disambiguate)

    -- v2.1: +wolverine, +fitch, +polecat; racoon/opossum alt spellings

    -- =================================================================

    REGEXP_CONTAINS(title_text, r'\bminks?\b')            AS t2_mink,

    REGEXP_CONTAINS(title_text, r'\bbobcats?\b')          AS t2_bobcat,

    REGEXP_CONTAINS(title_text, r'\bfox(?:es)?\b')        AS t2_fox,

    REGEXP_CONTAINS(title_text, r'\brabbits?\b')          AS t2_rabbit,

    REGEXP_CONTAINS(title_text, r'\brac+oons?\b')         AS t2_raccoon,   -- raccoon + racoon

    REGEXP_CONTAINS(title_text, r'\bwol(?:f|ves)\b')      AS t2_wolf,

    REGEXP_CONTAINS(title_text, r'\bsquirrels?\b')        AS t2_squirrel,

    REGEXP_CONTAINS(title_text, r'\bbeavers?\b')          AS t2_beaver,

    REGEXP_CONTAINS(title_text, r'\botters?\b')           AS t2_otter,

    REGEXP_CONTAINS(title_text, r'\bbadgers?\b')          AS t2_badger,

    REGEXP_CONTAINS(title_text, r'\bo?possums?\b')        AS t2_possum,    -- possum + opossum

    REGEXP_CONTAINS(title_text, r'\bhamsters?\b')         AS t2_hamster,

    REGEXP_CONTAINS(title_text, r'\bcoyotes?\b')          AS t2_coyote,

    REGEXP_CONTAINS(title_text, r'\bchinchillas?\b')      AS t2_chinchilla,

    REGEXP_CONTAINS(title_text, r'\bsable\b')             AS t2_sable,

    REGEXP_CONTAINS(title_text, r'\blynx\b')              AS t2_lynx,

    REGEXP_CONTAINS(title_text, r'\bwolverines?\b')       AS t2_wolverine,

    REGEXP_CONTAINS(title_text, r'\bfitch\b')             AS t2_fitch,

    REGEXP_CONTAINS(title_text, r'\bpolecats?\b')         AS t2_polecat,

    -- v2.8: new additions

    REGEXP_CONTAINS(title_text, r'\bkangaroos?\b')        AS t2_kangaroo,

    REGEXP_CONTAINS(title_text, r'\btanuki\b')            AS t2_tanuki,    -- raccoon dog (Japanese trade name)

    REGEXP_CONTAINS(title_text, r'\bfinn\s*coons?\b')     AS t2_finncoon,  -- Finnish raccoon dog (trade shorthand)

    REGEXP_CONTAINS(title_text, r'\bweasels?\b')          AS t2_weasel,

    REGEXP_CONTAINS(title_text, r'\bskunks?\b')           AS t2_skunk,

    REGEXP_CONTAINS(title_text, r'\bmarmots?\b')          AS t2_marmot,

    REGEXP_CONTAINS(title_text, r'\bstoats?\b')           AS t2_stoat,     -- ermine's year-round name; ermine is Tier 1



    -- =================================================================

    -- SEAL — removed as standalone; only compound forms

    -- =================================================================

    REGEXP_CONTAINS(title_tags_text, r'\bsealskin\b')             AS has_sealskin,

    REGEXP_CONTAINS(title_tags_text, r'\bseal\s+(?:fur|pelt)\b') AS has_seal_fur_pelt,



    -- =================================================================

    -- FUR CONTEXT SIGNALS

    -- Required for Tier 2 animals to qualify.  Checked in title + tags.

    -- =================================================================

    REGEXP_CONTAINS(title_tags_text, r'\bfur\b')                   AS ctx_fur,

    REGEXP_CONTAINS(title_tags_text, r'\bpelts?\b')                AS ctx_pelt,

    REGEXP_CONTAINS(title_tags_text, r'\btanned\b')                AS ctx_tanned,

    REGEXP_CONTAINS(title_tags_text, r'\bstole\b')                 AS ctx_stole,

    REGEXP_CONTAINS(title_tags_text, r'\breal\s+fur\b')            AS ctx_real_fur,

    REGEXP_CONTAINS(title_tags_text, r'\bgenuine\s+fur\b')         AS ctx_genuine_fur,

    REGEXP_CONTAINS(title_tags_text, r'\bnatural\s+fur\b')         AS ctx_natural_fur,  -- v2.6

    REGEXP_CONTAINS(title_tags_text, r'\bvintage\s+fur\b')         AS ctx_vintage_fur,

    REGEXP_CONTAINS(title_tags_text, r'\bknitted\s+fur\b')         AS ctx_knitted_fur,

    REGEXP_CONTAINS(title_tags_text, r'\bfull\s+skin\b')           AS ctx_full_skin,

    REGEXP_CONTAINS(title_tags_text, r'\blet\s+out\b')             AS ctx_let_out,

    REGEXP_CONTAINS(title_tags_text, r'\bskin\s+on\s+skin\b')      AS ctx_skin_on_skin,

    REGEXP_CONTAINS(title_tags_text, r'\bfur\s*lined\b')           AS ctx_fur_lined,

    REGEXP_CONTAINS(title_tags_text, r'\bguard\s+hairs?\b')        AS ctx_guard_hairs,

    REGEXP_CONTAINS(title_tags_text, r'\btrapp(?:ed|ing)\b')       AS ctx_trapped,

    REGEXP_CONTAINS(title_tags_text,

      r'\bfur\s+(?:coat|jacket|stole|wrap|cape|vest|collar|hat|blanket|throw|ruff|trim|cuff|muff|boa|shawl|poncho|gilet|bolero|headband|scarf|hood)\b'

    ) AS ctx_fur_garment,

    REGEXP_CONTAINS(title_tags_text, r'\bfur\s+plates?\b')  AS ctx_fur_plate,



    -- =================================================================

    -- KANGAROO HIDE/SKIN EXTENSION (v2.8)

    -- "hide" and "skin" serve the same role as "pelt" for kangaroo:

    -- kangaroo is sold as both leather (hair-off) and fur (hair-on), and

    -- hair-on hide sellers often use "hide"/"skin" rather than "fur"/"pelt".

    -- Evaluated as fur context ONLY when t2_kangaroo is also true (scored CTE).

    -- =================================================================

    REGEXP_CONTAINS(title_tags_text, r'\b(?:hide|skin)\b') AS ctx_hide_skin,



    -- =================================================================

    -- FUR AUCTION HOUSE BRANDS (v2.1)

    -- Near-perfect precision signals.  A listing mentioning these is

    -- almost certainly real fur.  Serve as fur context AND standalone.

    -- Removed: "american legend" (too generic — patriotic merch, bios),

    --          "nafa" (Swedish lamp brand "NAFA Nybro", archery org)

    -- =================================================================

    REGEXP_CONTAINS(title_tags_text,

      r'\b(?:blackglama|saga\s+furs?|kopenhagen\s+fur)\b'

    ) AS ctx_auction_brand,



    -- =================================================================

    -- NON-ENGLISH FUR TERMS (v2.1)

    -- Conservative set: French, German, Italian.  High precision based on spot-checks.

    --   fourrure   = French for fur

    --   pelliccia  = Italian for fur/fur coat

    --   nerz(...)  = German for mink (+ compounds: nerzmantel, etc.)

    -- Removed: "vison" (French for mink) — used as color name on Etsy

    --          like "mink brown" in English. 64 FPs from non-fur items.

    -- Removed: pelz* (v2.6) — material FPs from Pelznickel/Pelzmärtel and

    --          other non-fur German compounds; 92% of pelz* listings had no

    --          other non-English backup signal.

    -- =================================================================

    REGEXP_CONTAINS(title_tags_text,

      r'\b(?:fourrure|pelliccia|nerz\w*)\b'

    ) AS ctx_non_english_fur,



    -- =================================================================

    -- TAXIDERMY SIGNALS

    -- Includes skull/jawbone/bones which are common in oddities/taxidermy

    -- market and capture specimens from fur-trade animals (mink, bobcat, etc.)

    -- =================================================================

    REGEXP_CONTAINS(title_tags_text, r'\btaxiderm(?:y|ied|ist)?\b')           AS ctx_taxidermy,

    REGEXP_CONTAINS(title_tags_text, r'\b(?:shoulder|full\s+body)\s+mount\b') AS ctx_specific_mount,

    REGEXP_CONTAINS(title_tags_text, r'\bstudy\s+skin\b')                    AS ctx_study_skin,

    REGEXP_CONTAINS(title_tags_text, r'\bjawbones?\b')                        AS ctx_jawbone,

    REGEXP_CONTAINS(title_tags_text, r'\bbone\s+specimen\b')                  AS ctx_bone_specimen,

    -- v2.4: split ctx_oddities — oddities/curiosities are community identity tags,

    -- not reliable fur product indicators. Vulture culture is practice-specific; retained.

    REGEXP_CONTAINS(title_tags_text, r'\b(?:oddities|curiosities)\b') AS ctx_oddities_curiosities,

    REGEXP_CONTAINS(title_tags_text, r'\bvulture\s+culture\b')        AS ctx_vulture_culture,

    -- skull/claws tracked for diagnosis only — too noisy as standalone signals

    -- (3D printed skull masks, dragon claw nails, masquerade masks, etc.)

    REGEXP_CONTAINS(title_tags_text, r'\bskull\b')                            AS ctx_skull_diag,

    REGEXP_CONTAINS(title_tags_text, r'\bclaws?\b')                           AS ctx_claws_diag,



    -- =================================================================

    -- ANGORA — always-hard exclude (per original spec)

    -- =================================================================

    REGEXP_CONTAINS(title_tags_text, r'\bangora\b') AS has_angora,



    -- =================================================================

    -- HARD NEGATION

    -- Split strategy: tags for fabric compositions (seller-declared),

    -- title for clear faux indicators only.

    -- Rationale: "polyester lining" in a title ≠ faux product, but

    -- tagging "polyester" usually describes primary material.

    -- =================================================================



    -- Tag-based: seller-declared fabric compositions

    REGEXP_CONTAINS(tags_text,

      r'\b(polyester|poly|acrylic|modacrylic|faux|synthetic|vegan)\b'

    ) AS has_tag_negation,



    -- Title-based: unambiguous faux indicators only

    REGEXP_CONTAINS(title_text,

      r'\b(faux|synthetic|vegan|fake|imitation|artificial)\b'

    ) AS has_title_negation,



    -- Faux proximity: "faux/vegan/synthetic [opt word] animal/fur" in title

    REGEXP_CONTAINS(title_text,

      r'\b(?:faux|vegan|synthetic|fake|imitation|artificial)\s+(?:\w+\s+)?(?:fur|mink|fox|rabbit|chinchilla|sable|beaver|rac+oon|coyote|marten|wolf|lynx|bobcat|otter|badger|ermine|o?possum|muskrat|nutria|squirrel|hamster|[ck]ara[ck]ul|astra[ck]han|broadtail|orylag|wolverine|fitch|polecat|persian\s+lamb|kangaroo|tanuki|finn\s*coon|weasel|skunk|marmot|stoat)\b'

    ) AS has_faux_proximity,



    -- =================================================================

    -- DESCRIPTION-BASED FAUX DETECTION (v2.2)

    -- Catches items where title is ambiguous but description declares

    -- faux/synthetic materials.  Only excludes when description does NOT

    -- also claim "real fur" / "genuine fur" (handled in scored CTE).

    -- Normalized inline here (not in with_text) so the expensive

    -- LOWER/REGEXP_REPLACE only runs on the smaller candidates set.

    -- =================================================================

    REGEXP_CONTAINS(

      LOWER(COALESCE(description, '')),

      r'\b(?:faux|fake|synthetic|artificial|imitation)\s+fur\b'

    ) AS has_desc_faux_fur,

    REGEXP_CONTAINS(

      LOWER(COALESCE(description, '')),

      r'\b(?:real|genuine)\s+fur\b'

    ) AS has_desc_real_fur,



    -- =================================================================

    -- PET MEMORIAL / URN PRODUCTS (v2.2)

    -- Items themed around pet loss — animal names present for the pet,

    -- not for fur trade.  Only excluded if no strong fur product term

    -- is also present (handled in classified CTE).

    -- =================================================================

    REGEXP_CONTAINS(title_text,

      r'\b(?:memorial|urn|cremation|pet\s+loss|rainbow\s+bridge|in\s+memory)\b'

    ) AS has_pet_memorial,



    -- =================================================================

    -- BYPRODUCT ANIMALS

    -- Used to exclude product-term-only matches (sheepskin rugs, etc.)

    -- NOT used to exclude Tier 1/2 animal matches (fur-trade animal wins).

    -- Includes shearling/toscana (sheepskin by another name).

    -- =================================================================

    REGEXP_CONTAINS(title_tags_text,

      r'\b(sheep(?:skin)?|lamb(?:skin)?|shearling|toscana|reindeer|cow(?:hide)?|goat(?:skin)?|deer(?:skin)?|elk|bison|buffalo|alpaca|llama|yak|camel|ostrich|mouton|horse(?:hide)?|pig(?:skin)?|pheasants?)\b'

    ) AS has_byproduct_animal,



    -- =================================================================

    -- STICKER / DECAL PAPER PRODUCTS (v2.3)

    -- Paper/vinyl goods with animal imagery — "fox fur sticker" is a

    -- sticker depicting a fox, not a fur product.  Only excluded when

    -- no strong fur product term is present (handled in classified CTE).

    -- =================================================================

    REGEXP_CONTAINS(title_text,

      r'\b(?:stickers?|decals?|vinyl\s+decal)\b'

    ) AS has_sticker_decal,



    -- =================================================================

    -- SPECIFIC FALSE POSITIVE PATTERNS

    -- =================================================================

    REGEXP_CONTAINS(title_text, r'\bmink\s+oil\b') AS is_mink_oil,

    -- "Doc Marten" / "Dr Marten" boots — not the animal marten

    REGEXP_CONTAINS(title_text, r'\b(?:doc|dr|doctor)\s+martens?\b') AS is_doc_marten,

    -- "Abercrombie & Fitch" brand — not the animal fitch

    REGEXP_CONTAINS(title_text, r'\babercrombie\b') AS is_abercrombie_fitch,

    -- "Van Pelt" surname — not the material pelt (v2.3)

    REGEXP_CONTAINS(title_text, r'\bvan\s+pelt\b') AS is_van_pelt,



    -- =================================================================

    -- FURSUIT COSTUMES (v2.5)

    -- Synthetic fur costume items where "fursuit" appears in the title.

    -- Override: real-fur items tagged for the fursuit community retain

    -- their match because has_strong_fur_term_in_title or tag-level

    -- real-fur signals prevent this exclusion from firing.

    -- =================================================================

    REGEXP_CONTAINS(title_text, r'\bfursuit\b') AS has_fursuit_title,



    -- =================================================================

    -- CONTEXT TERMS — tracked for audit, non-excluding

    -- =================================================================

    REGEXP_CONTAINS(title_tags_text, r'\bwool\b')      AS ctx_wool,

    REGEXP_CONTAINS(title_tags_text, r'\bleather\b')    AS ctx_leather,

    REGEXP_CONTAINS(title_tags_text, r'\bshearling\b')  AS ctx_shearling,

    REGEXP_CONTAINS(title_tags_text, r'\bsuede\b')      AS ctx_suede



  FROM candidates c

),



-- =============================================================================

-- CTE 5: scored

-- Build compound flags from individual term flags.

-- =============================================================================

scored AS (

  SELECT

    m.*,



    -- Any Tier 1 animal in title (Doc Marten boot FP excluded)

    (

      (t1_marten AND NOT is_doc_marten) OR t1_ermine OR t1_karakul OR

      t1_astrachan OR t1_broadtail OR t1_orylag OR t1_nutria OR t1_muskrat OR

      t1_persian_lamb

    ) AS has_tier1,



    -- Any Tier 2 animal in title (now includes mink and bobcat)

    (

      t2_mink OR t2_bobcat OR t2_fox OR t2_rabbit OR t2_raccoon OR

      t2_wolf OR t2_squirrel OR t2_beaver OR t2_otter OR t2_badger OR

      t2_possum OR t2_hamster OR t2_coyote OR t2_chinchilla OR

      t2_sable OR t2_lynx OR t2_wolverine OR

      (t2_fitch AND NOT is_abercrombie_fitch) OR t2_polecat OR

      -- v2.8 additions

      t2_kangaroo OR t2_tanuki OR t2_finncoon OR

      t2_weasel OR t2_skunk OR t2_marmot OR t2_stoat

    ) AS has_tier2,



    -- Any fur context signal present (includes taxidermy signals)

    -- skull/claws excluded: too noisy (3D printed masks, fursuits, nail art)

    -- v2.4: ctx_oddities_curiosities removed; ctx_vulture_culture retained

    (

      ctx_fur OR ctx_pelt OR ctx_tanned OR ctx_stole OR ctx_real_fur OR

      ctx_genuine_fur OR ctx_natural_fur OR ctx_vintage_fur OR ctx_knitted_fur OR

      ctx_full_skin OR ctx_let_out OR ctx_skin_on_skin OR ctx_fur_lined OR

      ctx_guard_hairs OR ctx_trapped OR ctx_fur_garment OR ctx_fur_plate OR

      ctx_taxidermy OR ctx_specific_mount OR ctx_study_skin OR

      ctx_jawbone OR ctx_bone_specimen OR ctx_vulture_culture OR

      ctx_auction_brand OR ctx_non_english_fur OR

      -- v2.8: kangaroo-specific — hide/skin qualify as fur context only for kangaroo

      (t2_kangaroo AND ctx_hide_skin)

    ) AS has_fur_context,



    -- Any taxidermy signal (for distinct classification)

    -- skull/claws excluded: decorative skull art/masks and "dragon claw"

    -- nails dominate these terms on Etsy

    -- v2.4: ctx_oddities_curiosities removed; ctx_vulture_culture retained

    (

      ctx_taxidermy OR ctx_specific_mount OR ctx_study_skin OR

      ctx_jawbone OR ctx_bone_specimen OR ctx_vulture_culture

    ) AS has_taxidermy_signal,



    -- Seal compound forms

    (has_sealskin OR has_seal_fur_pelt) AS has_seal_compound,



    -- Explicit fur declaration in title (v2.6): real/genuine/natural fur

    -- Fires as EXPLICIT_FUR_DECLARATION before tier detection.

    REGEXP_CONTAINS(title_text, r'\b(?:real|genuine|natural)\s+fur\b')

      AS has_explicit_fur_declaration,



    -- Strong standalone fur product terms (can qualify WITHOUT a named animal)

    -- Requires the term to appear in TITLE (not just tags) for precision.

    -- Excludes generic "fur [garment]" — too noisy without an animal name.

    -- Only high-confidence standalone signals: explicit real/genuine/natural/vintage fur,

    -- pelt (in title, excluding "van pelt" surname), knitted fur, full skin,

    -- fur plate, auction brands, non-English fur terms.

    (

      REGEXP_CONTAINS(title_text, r'\breal\s+fur\b') OR

      REGEXP_CONTAINS(title_text, r'\bgenuine\s+fur\b') OR

      REGEXP_CONTAINS(title_text, r'\bnatural\s+fur\b') OR

      REGEXP_CONTAINS(title_text, r'\bvintage\s+fur\b') OR

      REGEXP_CONTAINS(title_text, r'\bknitted\s+fur\b') OR

      (REGEXP_CONTAINS(title_text, r'\bpelts?\b') AND NOT is_van_pelt) OR

      REGEXP_CONTAINS(title_text, r'\bfull\s+skin\b') OR

      REGEXP_CONTAINS(title_text, r'\bfur\s+plates?\b') OR

      REGEXP_CONTAINS(title_text,

        r'\b(?:blackglama|saga\s+furs?|kopenhagen\s+fur)\b') OR

      REGEXP_CONTAINS(title_text,

        r'\b(?:fourrure|pelliccia|nerz\w*)\b')

    ) AS has_strong_fur_term_in_title,



    -- Combined hard negation (v2.2: includes description faux detection)

    (has_tag_negation OR has_title_negation OR (has_desc_faux_fur AND NOT has_desc_real_fur)) AS has_hard_negation



  FROM matched m

),



-- =============================================================================

-- CTE 6: classified

-- Apply priority-ordered business logic for match_rule and is_fur_trade.

-- =============================================================================

classified AS (

  SELECT

    listing_id,

    user_id,

    shop_id,

    title,

    taxonomy_id,

    top_category,

    full_path,

    past_year_gms,

    past_year_orders,

    how_its_made_label,

    price_usd,



    -- ----- Diagnosis: matched Tier 1 animals -----

    (SELECT STRING_AGG(x, ', ') FROM UNNEST([

      IF(t1_marten AND NOT is_doc_marten, 'marten', NULL),

      IF(t1_ermine,       'ermine',       NULL),

      IF(t1_karakul,      'karakul',      NULL),

      IF(t1_astrachan,    'astrachan',    NULL),

      IF(t1_broadtail,    'broadtail',    NULL),

      IF(t1_orylag,       'orylag',       NULL),

      IF(t1_nutria,       'nutria',       NULL),

      IF(t1_muskrat,      'muskrat',      NULL),

      IF(t1_persian_lamb, 'persian_lamb', NULL)

    ]) x WHERE x IS NOT NULL) AS matched_tier1_animals,



    -- ----- Diagnosis: matched Tier 2 animals -----

    (SELECT STRING_AGG(x, ', ') FROM UNNEST([

      IF(t2_mink,       'mink',       NULL),

      IF(t2_bobcat,     'bobcat',     NULL),

      IF(t2_fox,        'fox',        NULL),

      IF(t2_rabbit,     'rabbit',     NULL),

      IF(t2_raccoon,    'raccoon',    NULL),

      IF(t2_wolf,       'wolf',       NULL),

      IF(t2_squirrel,   'squirrel',   NULL),

      IF(t2_beaver,     'beaver',     NULL),

      IF(t2_otter,      'otter',      NULL),

      IF(t2_badger,     'badger',     NULL),

      IF(t2_possum,     'possum',     NULL),

      IF(t2_hamster,    'hamster',    NULL),

      IF(t2_coyote,     'coyote',     NULL),

      IF(t2_chinchilla, 'chinchilla', NULL),

      IF(t2_sable,      'sable',      NULL),

      IF(t2_lynx,       'lynx',       NULL),

      IF(t2_wolverine,  'wolverine',  NULL),

      IF(t2_fitch,      'fitch',      NULL),

      IF(t2_polecat,    'polecat',    NULL),

      IF(t2_kangaroo,   'kangaroo',   NULL),

      IF(t2_tanuki,     'tanuki',     NULL),

      IF(t2_finncoon,   'finncoon',   NULL),

      IF(t2_weasel,     'weasel',     NULL),

      IF(t2_skunk,      'skunk',      NULL),

      IF(t2_marmot,     'marmot',     NULL),

      IF(t2_stoat,      'stoat',      NULL)

    ]) x WHERE x IS NOT NULL) AS matched_tier2_animals,



    -- ----- Diagnosis: fur context signals found -----

    (SELECT STRING_AGG(x, ', ') FROM UNNEST([

      IF(ctx_fur,              'fur',              NULL),

      IF(ctx_pelt,             'pelt',             NULL),

      IF(ctx_tanned,           'tanned',           NULL),

      IF(ctx_stole,            'stole',            NULL),

      IF(ctx_real_fur,         'real fur',         NULL),

      IF(ctx_genuine_fur,      'genuine fur',      NULL),

      IF(ctx_natural_fur,      'natural fur',      NULL),

      IF(ctx_vintage_fur,      'vintage fur',      NULL),

      IF(ctx_knitted_fur,      'knitted fur',      NULL),

      IF(ctx_full_skin,        'full skin',        NULL),

      IF(ctx_let_out,          'let-out',          NULL),

      IF(ctx_skin_on_skin,     'skin-on-skin',     NULL),

      IF(ctx_fur_lined,        'fur-lined',        NULL),

      IF(ctx_guard_hairs,      'guard hairs',      NULL),

      IF(ctx_trapped,          'trapped/trapping', NULL),

      IF(ctx_fur_garment,      'fur garment',      NULL),

      IF(ctx_fur_plate,        'fur plate',        NULL),

      IF(ctx_auction_brand,    'auction brand',    NULL),

      IF(ctx_non_english_fur,  'non-english fur',  NULL),

      IF(ctx_hide_skin AND t2_kangaroo, 'kangaroo hide/skin', NULL),

      IF(ctx_taxidermy,        'taxidermy',        NULL),

      IF(ctx_specific_mount,   'specific mount',   NULL),

      IF(ctx_study_skin,       'study skin',       NULL),

      IF(ctx_skull_diag,       'skull',            NULL),

      IF(ctx_jawbone,          'jawbone',          NULL),

      IF(ctx_bone_specimen,    'bone specimen',    NULL),

      IF(ctx_claws_diag,       'claws',            NULL),

      IF(ctx_oddities_curiosities, 'oddities/curiosities', NULL),

      IF(ctx_vulture_culture,  'vulture culture',  NULL),

      IF(has_sealskin,         'sealskin',         NULL),

      IF(has_seal_fur_pelt,    'seal fur/pelt',    NULL)

    ]) x WHERE x IS NOT NULL) AS matched_fur_context,



    -- ----- Diagnosis: negation terms -----

    (SELECT STRING_AGG(x, ', ') FROM UNNEST([

      IF(has_angora,         'angora',         NULL),

      IF(has_tag_negation,   'tag_negation',   NULL),

      IF(has_title_negation, 'title_negation', NULL),

      IF(has_faux_proximity, 'faux_proximity', NULL),

      IF(has_desc_faux_fur AND NOT has_desc_real_fur, 'desc_faux_fur', NULL),

      IF(has_pet_memorial,        'pet_memorial',        NULL),

      IF(is_mink_oil,             'mink_oil',            NULL),

      IF(is_doc_marten,           'doc_marten',          NULL),

      IF(is_abercrombie_fitch,    'abercrombie_fitch',   NULL),

      IF(is_van_pelt,             'van_pelt',            NULL),

      IF(has_sticker_decal,       'sticker_decal',       NULL),

      IF(has_fursuit_title,       'fursuit_title',       NULL)

    ]) x WHERE x IS NOT NULL) AS matched_negation_terms,



    -- ----- Diagnosis: context terms (non-excluding) -----

    (SELECT STRING_AGG(x, ', ') FROM UNNEST([

      IF(ctx_wool,             'wool',             NULL),

      IF(ctx_leather,          'leather',          NULL),

      IF(ctx_shearling,        'shearling',        NULL),

      IF(ctx_suede,            'suede',            NULL),

      IF(has_byproduct_animal, 'byproduct_animal', NULL)

    ]) x WHERE x IS NOT NULL) AS matched_context_terms,



    -- ----- Match rule (priority-ordered decision tree) -----

    CASE

      -- === EXCLUSIONS (highest priority) ===

      WHEN has_angora

        THEN 'EXCLUDED_ANGORA'

      WHEN has_faux_proximity

        THEN 'EXCLUDED_FAUX_PROXIMITY'

      WHEN has_hard_negation

        THEN 'EXCLUDED_HARD_NEGATION'

      WHEN has_pet_memorial AND NOT has_strong_fur_term_in_title

        THEN 'EXCLUDED_PET_MEMORIAL'

      WHEN has_sticker_decal AND NOT has_strong_fur_term_in_title

        THEN 'EXCLUDED_STICKER_DECAL'

      WHEN has_fursuit_title AND NOT has_strong_fur_term_in_title

        AND NOT REGEXP_CONTAINS(tags_text, r'\breal\s*fur\b|\bgenuine\s*fur\b|\breal\s+pelt\b')

        THEN 'EXCLUDED_FURSUIT'



      -- === TAXIDERMY of fur-trade animals ===

      -- v2.4: guard — if a strong fur product term appears in title, the listing

      -- is a fur pelt seller using "taxidermy" as a use-case descriptor, not a

      -- taxidermy operation. Fall through to tier rules for correct classification.

      WHEN has_taxidermy_signal AND (has_tier1 OR has_tier2) AND NOT has_strong_fur_term_in_title

        THEN 'TAXIDERMY_FUR_ANIMAL'



      -- === EXPLICIT FUR DECLARATION: real/genuine/natural fur in title (v2.6) ===

      -- Fires before animal-tier detection — explicit claims are high-confidence

      -- regardless of which animal (or no animal) is named.

      -- Byproduct animal guard prevents sheepskin/lambskin FPs ("real sheepskin fur").

      WHEN has_explicit_fur_declaration AND NOT has_byproduct_animal

        THEN 'EXPLICIT_FUR_DECLARATION'



      -- === TIER 1: low-ambiguity animal in title ===

      WHEN has_tier1 AND has_fur_context

        THEN 'TIER1_WITH_FUR_CONTEXT'

      WHEN has_tier1

        THEN 'TIER1_STANDALONE'



      -- === TIER 2: high-ambiguity animal + fur context required ===

      WHEN has_tier2 AND has_fur_context

        THEN 'TIER2_WITH_FUR_CONTEXT'



      -- === SEAL compound forms ===

      WHEN has_seal_compound

        THEN 'SEAL_COMPOUND'



      -- === Strong fur product terms in TITLE (no named fur-trade animal) ===

      -- Requires term in title (not just tags) for precision.

      -- Excludes if byproduct animal present (sheepskin/shearling/etc.)

      WHEN has_strong_fur_term_in_title AND NOT has_byproduct_animal

        THEN 'FUR_PRODUCT_TERM_ONLY'



      ELSE 'NO_MATCH'

    END AS match_rule,



    -- ----- Final boolean -----

    CASE

      WHEN has_angora THEN FALSE

      WHEN has_faux_proximity THEN FALSE

      WHEN has_hard_negation THEN FALSE

      WHEN has_pet_memorial AND NOT has_strong_fur_term_in_title THEN FALSE

      WHEN has_sticker_decal AND NOT has_strong_fur_term_in_title THEN FALSE

      WHEN has_fursuit_title AND NOT has_strong_fur_term_in_title

        AND NOT REGEXP_CONTAINS(tags_text, r'\breal\s*fur\b|\bgenuine\s*fur\b|\breal\s+pelt\b') THEN FALSE

      WHEN has_taxidermy_signal AND (has_tier1 OR has_tier2) AND NOT has_strong_fur_term_in_title THEN TRUE

      WHEN has_explicit_fur_declaration AND NOT has_byproduct_animal THEN TRUE

      WHEN has_tier1 THEN TRUE

      WHEN has_tier2 AND has_fur_context THEN TRUE

      WHEN has_seal_compound THEN TRUE

      WHEN has_strong_fur_term_in_title AND NOT has_byproduct_animal THEN TRUE

      ELSE FALSE

    END AS is_fur_trade,



    -- ----- Vintage flag -----

    -- Title-level keyword: "vintage" or "antique"

    REGEXP_CONTAINS(title_text, r'\b(?:vintage|antique)\b') AS is_vintage



  FROM scored

)



-- =============================================================================

-- Final output: fur trade listings only, ordered by past-year GMS

-- =============================================================================

SELECT

  listing_id,

  user_id,

  shop_id,

  title,

  taxonomy_id,

  top_category,

  full_path,

  past_year_gms,

  past_year_orders,

  how_its_made_label,

  price_usd,

  matched_tier1_animals,

  matched_tier2_animals,

  matched_fur_context,

  matched_negation_terms,

  matched_context_terms,

  match_rule,

  is_fur_trade,

  is_vintage,

  CASE

    WHEN REGEXP_CONTAINS(COALESCE(matched_fur_context, ''), r'auction.brand')

      THEN '01_HIGH_auction_brand'

    WHEN match_rule = 'EXPLICIT_FUR_DECLARATION'

      THEN '02_HIGH_explicit_declaration'

    WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'

      AND REGEXP_CONTAINS(COALESCE(matched_tier2_animals, ''), r'\b(?:fox|mink)\b')

      THEN '03_HIGH_fox_mink'

    WHEN REGEXP_CONTAINS(COALESCE(matched_fur_context, ''), r'non.english fur')

      THEN '04_HIGH_non_english'

    WHEN match_rule = 'TIER1_WITH_FUR_CONTEXT'

      THEN '05_HIGH_tier1_with_context'

    WHEN match_rule = 'TIER1_STANDALONE'

      THEN '06_HIGH_tier1_standalone'

    WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'

      AND REGEXP_CONTAINS(COALESCE(matched_tier2_animals, ''), r'\brabbit\b')

      AND top_category IN ('clothing', 'accessories', 'bags_and_purses')

      THEN '07_HIGH_rabbit_sampled_cats'

    WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'

      AND REGEXP_CONTAINS(COALESCE(matched_tier2_animals, ''), r'\brabbit\b')

      THEN '08_MEDIUM_rabbit_other_cats'

    WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'

      AND top_category IN ('clothing', 'accessories', 'craft_supplies_and_tools')

      THEN '09_MEDIUM_unsampled_tier2_reviewed'

    WHEN match_rule = 'FUR_PRODUCT_TERM_ONLY'

      THEN '10_REVIEW_fur_product_term_only'

    WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'

      THEN '11_REVIEW_unsampled_tier2_other'

    ELSE 'OTHER'

  END AS confidence_tier,

  CASE

    WHEN REGEXP_CONTAINS(COALESCE(matched_fur_context, ''), r'auction.brand') THEN 'HIGH'

    WHEN match_rule = 'EXPLICIT_FUR_DECLARATION' THEN 'HIGH'

    WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'

      AND REGEXP_CONTAINS(COALESCE(matched_tier2_animals, ''), r'\b(?:fox|mink)\b') THEN 'HIGH'

    WHEN REGEXP_CONTAINS(COALESCE(matched_fur_context, ''), r'non.english fur') THEN 'HIGH'

    WHEN match_rule = 'TIER1_WITH_FUR_CONTEXT' THEN 'HIGH'

    WHEN match_rule = 'TIER1_STANDALONE' THEN 'HIGH'

    WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'

      AND REGEXP_CONTAINS(COALESCE(matched_tier2_animals, ''), r'\brabbit\b')

      AND top_category IN ('clothing', 'accessories', 'bags_and_purses') THEN 'HIGH'

    WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'

      AND REGEXP_CONTAINS(COALESCE(matched_tier2_animals, ''), r'\brabbit\b') THEN 'MEDIUM'

    WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT'

      AND top_category IN ('clothing', 'accessories', 'craft_supplies_and_tools') THEN 'MEDIUM'

    WHEN match_rule = 'FUR_PRODUCT_TERM_ONLY' THEN 'REVIEW'

    WHEN match_rule = 'TIER2_WITH_FUR_CONTEXT' THEN 'REVIEW'

    ELSE 'OTHER'

  END AS confidence_band

FROM classified

WHERE is_fur_trade = TRUE

  -- Seal is a separate policy area; taxidermy is generally not from the

  -- commercial fur trade.

  AND match_rule != 'SEAL_COMPOUND'

  AND match_rule != 'TAXIDERMY_FUR_ANIMAL'

  -- TIER1_STANDALONE: animal-only title match is only reliable in specific

  -- subcategories confirmed by full_path analysis (v2.7). Top-level allowlist

  -- was too broad (jewelry, t-shirts, keychains, china were FPs).

  AND NOT (

    match_rule = 'TIER1_STANDALONE'

    AND NOT REGEXP_CONTAINS(COALESCE(full_path, ''),

      r'jackets_and_coats|hats_and_caps|raw_materials\.leather|^home_and_living\.floor_and_rugs|\.dresses|\.vests|bags_and_purses|accessories\.(?:gloves_and_sleeves|collars|scarves)|^weddings')

  )

  -- Electronics: definitively not fur trade items (v2.7).

  AND NOT REGEXP_CONTAINS(COALESCE(full_path, ''), r'^electronics_and_accessories')

  -- Art subcategories: prints/photography/painting always excluded (describe

  -- subject, not material). Sculpture/figurines excluded UNLESS real fur declared.

  AND NOT REGEXP_CONTAINS(COALESCE(full_path, ''),

    r'^art_and_collectibles\.(prints|painting|photography)')

  AND NOT (

    REGEXP_CONTAINS(COALESCE(full_path, ''),

      r'^art_and_collectibles\.sculpture|art_and_collectibles\.collectibles\.figurines')

    AND match_rule != 'EXPLICIT_FUR_DECLARATION'

  )

ORDER BY past_year_gms DESC NUL