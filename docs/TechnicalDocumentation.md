# 🔬 Technical Documentation: Logistics Account Health & Growth Analytics

This document covers the full methodology, data-cleaning decisions, SQL walkthroughs, data dictionary, and limitations behind the project. For a high-level overview, see the [README](../README.md).

---

## Table of Contents

1. [Pipeline Architecture](#pipeline-architecture)
2. [Data Dictionary](#data-dictionary)
3. [Synthetic Dirty-Data Generation Methodology](#synthetic-dirty-data-generation-methodology)
4. [Data Cleaning: Phase-by-Phase Deep Dive](#data-cleaning-phase-by-phase-deep-dive)
5. [Star Schema: Fact & Dimension Layer](#star-schema-fact--dimension-layer)
6. [Mart Views: Module-by-Module Deep Dive](#mart-views-module-by-module-deep-dive)
7. [Key Findings & Dashboard Layout](#key-findings--dashboard-layout)
8. [Recommendations](#recommendations)
9. [Execution Guide](#execution-guide)
10. [Limitations & Assumptions](#limitations--assumptions)
11. [Future Work](#future-work)

---

## Pipeline Architecture

The platform follows a 4-stage end-to-end pipeline:

```
┌──────────────────┐    ┌──────────────────────┐    ┌───────────────────────┐    ┌──────────────────┐
│ 1. Data Gen       │───►│ 2. Data Cleaning      │───►│ 3. Star Schema        │───►│ 4. Mart Views &   │
│ (Python/Faker)     │    │ (01_data_cleaning.sql)│    │ (fact_order_item +    │    │ BI Dashboard      │
│                    │    │                       │    │  dim_date/customer/   │    │ (Power BI)        │
│                    │    │                       │    │  product)             │    │                    │
└──────────────────┘    └──────────────────────┘    └───────────────────────┘    └──────────────────┘
```

1. **Data Generation** — `python/generate_dataset.py` reshapes the DataCo Smart Supply Chain schema and deliberately injects realistic data-quality problems (~223,300 rows) so the cleaning phase has genuine, non-trivial work to do.
2. **Data Cleaning** — `sql/01_data_cleaning.sql`, split into four diagnose-then-fix sections against BigQuery: keys/IDs/dates, delivery/status fields, money/quantity fields, segmentation dimensions. Output: `stg_orders_final`.
3. **Star Schema** — `sql/02`–`06`: builds `fact_order_item` (grain: one row per order line) plus `dim_date`, `dim_customer`, `dim_product`, with full referential-integrity validation.
4. **Mart Views & Dashboard** — `sql/07`–`14`: four module-specific views (`mart_funnel`, `mart_cohort`, `mart_churn_rfm`, `mart_ltv`), each with its own validation queries, feeding a Power BI dashboard.

---

## Data Dictionary

`dirty_supply_chain_dataset.csv` mirrors the DataCo Smart Supply Chain schema (53 columns). Only the ~20 columns actually consumed by the four analytical modules were cleaned; the rest (`customer_email`, `customer_password`, `product_image`, `product_description`, `latitude`/`longitude`, zip codes, etc.) were deliberately left out of cleaning scope — see [Limitations & Assumptions](#limitations--assumptions) for why.

### Keys / IDs

| Column | Type | Description |
|---|---|---|
| `order_item_id` | INT64 | Grain of `fact_order_item` — one row per order line |
| `order_id` | INT64 | Order-level identifier; one order can span multiple `order_item_id` rows |
| `customer_id` / `order_customer_id` | INT64 | Customer identifier (confirmed 100% consistent between the two columns) |
| `product_card_id` / `order_item_cardprod_id` | INT64 | Product identifier |

### Dates

| Column | Type | Description |
|---|---|---|
| `order_date` → `order_date_clean` | STRING → DATE | Parsed from mixed formats (`DD/MM/YYYY`, `MM/DD/YYYY`, `DD-Mon-YY`, ISO, etc.); ambiguity resolved via same-convention pairing against `shipping_date` |
| `shipping_date` → `shipping_date_clean` | STRING → DATE | Same treatment as `order_date` |

### Delivery / Status

| Column | Type | Description |
|---|---|---|
| `order_status` | STRING → cleaned enum | 9 canonical values (COMPLETE, CANCELED, PENDING, PROCESSING, CLOSED, PAYMENT_REVIEW, SUSPECTED_FRAUD, ON_HOLD, PENDING_PAYMENT) |
| `delivery_status` | STRING → cleaned enum | 4 canonical values (Advance shipping, Late delivery, Shipping canceled, Shipping on time) |
| `shipping_mode` | STRING → cleaned enum | 4 canonical values (Standard Class, First Class, Second Class, Same Day) |
| `late_delivery_risk` | mixed → INT64 0/1 | Normalized from 12+ raw representations (0/1, TRUE/FALSE, YES/NO, Y/N, mixed case) |
| `real_shipping_days` / `scheduled_days_for_shipment` | STRING → INT64 | Cast from STRING (embedded null-flavors forced STRING typing on load) |

### Money / Quantity

| Column | Type | Description |
|---|---|---|
| `sales`, `order_item_total`, `order_item_product_price`, `order_item_discount`, `order_profit_per_order`, `benefit_per_order`, `sales_per_customer` | STRING → FLOAT64 | Parsed from mixed currency formats (`$1,504.42`, `2256,63` European-decimal style, plain numeric) |
| `order_item_discount_rate`, `order_item_profit_ratio` | STRING → FLOAT64 | Straight cast (never received $/comma formatting) |
| `order_item_quantity` | STRING → INT64 | ~21% of rows carry business-invalid values (-1 or 0) by design — flagged via `is_quantity_invalid`, not dropped |

### Segmentation Dimensions

| Column | Type | Description |
|---|---|---|
| `customer_segment` | STRING → cleaned enum | Consumer / Corporate / Home Office |
| `order_region` | STRING → cleaned enum | 16 canonical regions |
| `market` | STRING → cleaned enum | USCA / LATAM / Pacific Asia / Europe / Africa |
| `order_country` | STRING → cleaned enum | 7 countries (United States, Vietnam, Ireland, Germany, Mexico, Brazil, Australia) — resolved via explicit mapping table, not pattern matching, since variants are genuinely different spellings/abbreviations (USA/US/u.s.a./United States) |
| `order_state` | STRING → cleaned | High-cardinality reference data (67 distinct values); null-flavor handling only, no canonical mapping |

### Quality Flags

Every cleaned field has a companion `is_<field>_missing` boolean flag carried through to `fact_order_item`, plus `is_ship_before_order_flag` and `is_quantity_invalid`. Downstream mart views filter on these explicitly rather than the cleaning step silently dropping ambiguous rows.

---

## Synthetic Dirty-Data Generation Methodology

**File:** `python/generate_dataset.py`

Rather than starting from a clean CSV, the generator builds ~223,300 rows against the DataCo schema and deliberately injects the categories of data-quality problems a real production export would have — so the cleaning phase (Section 4 below) has genuine, non-trivial work to solve, not a token exercise.

**Injected problems, by category:**

- **Null-flavor diversity** (`maybe_null()`): every cleaned field has a ~6% chance of being replaced with one of nine different "looks like data but isn't" representations — `NaN`, `""`, `"N/A"`, `"n/a"`, `"null"`, `"NULL"`, `"-"`, `"??"`, `" "` — forcing the cleaning logic to recognize all of them, not just a single `NULL` check.
- **Mixed date formats** (`dirty_date()`): six different date format strings applied at random, plus a 5% rate of genuinely broken values (`"31/13/2026 25:99"`, `"2026-02-30 10:00:00"`, `"0000-00-00"`) and a 4% rate of missing dates — critically, both `MM/DD/YYYY` and `DD/MM/YYYY` conventions coexist in the same column, so a single format string cannot resolve every row.
- **Currency format chaos** (`dirty_money()`): ~25% of monetary values are rendered as dirty strings — `"$1,504.42"` (dollar sign + thousands comma), `"2256,63"` (European-style decimal comma, no dollar sign), or plain numeric — requiring different parsing logic depending on which pattern is present.
- **Categorical inconsistency** (`dirty_case()`, `dirty_country()`): random upper/lowercasing, leading/trailing whitespace, and — critically — genuine spelling/abbreviation variants for country names (`COUNTRY_VARIANTS` dict: e.g. `"United States"` → `["United States", "USA", "US", "u.s.a.", "United States ", "usa"]`), which cannot be resolved by case-normalization alone and require an explicit mapping table.
- **Junk substrings** (`JUNK_SNIPPETS`): HTML-adjacent artifacts (`"<br>"`, `"&nbsp;"`, zero-width spaces, tabs, `"###"`, `"N/A - check later"`) appended to otherwise-valid values, simulating a scraped or copy-pasted export.
- **Boolean chaos**: `late_delivery_risk` rendered as 12 different representations — `0/1`, `True/False`, `Yes/No`, `Y/N`, in mixed case.
- **Structural duplication**: ~1.5% of rows are exact full-row duplicates (simulating a retry/re-export), plus ~0.2% of `Order Item Id` values intentionally collide across genuinely different rows (simulating an ID-generation bug).
- **Business-invalid values**: `order_item_quantity` includes `-1` and `0` alongside valid positive quantities, at roughly 2/9 frequency — testing whether the cleaning logic distinguishes "unparseable" from "parseable but logically wrong."

This design means every category of real-world messiness encountered during cleaning (Section 4) was intentional, not accidental — the generator's docstring-level comments map directly to the diagnostic queries used to discover each problem.

---

## Data Cleaning: Phase-by-Phase Deep Dive

**File:** `sql/01_data_cleaning.sql` — four sections, each following the same diagnose → fix → validate pattern against BigQuery.

### Section A: Keys / IDs / Dates

**Problem 1 — ID collisions requiring a non-arbitrary tie-breaker.** After removing 3,300 exact full-row duplicates, 429 rows still shared an `order_item_id` with a genuinely different row. Resolving this required a *parsed* date as the tie-breaker (earliest wins) — which meant date parsing had to happen *before* ID deduplication, not after, reversing the naive build order.

**Problem 2 — Two coexisting date conventions.** Initial `SAFE.PARSE_DATETIME` attempts using only `MM/DD/YYYY` left ~51% of rows unparsed; adding `DD/MM/YYYY` brought it to 27%; the residual pattern (further diagnostic sampling) revealed the raw data genuinely mixes both conventions row-to-row, with no per-row indicator of which is in use.

**Technical decision — same-convention pairing:**
```sql
-- Resolve ambiguity using order_date and shipping_date TOGETHER, not independently
CASE
  -- Case 1: one side is unambiguous -> use it to disambiguate the other
  WHEN order_date_forced IS NOT NULL THEN order_date_forced
  WHEN shipping_date_forced IS NOT NULL AND order_date_monthfirst <= shipping_date_forced THEN order_date_monthfirst
  WHEN shipping_date_forced IS NOT NULL AND order_date_dayfirst   <= shipping_date_forced THEN order_date_dayfirst
  -- Case 2: both ambiguous -> try same-convention pairs (both month-first OR both day-first)
  WHEN order_date_monthfirst <= shipping_date_monthfirst THEN order_date_monthfirst
  WHEN order_date_dayfirst   <= shipping_date_dayfirst   THEN order_date_dayfirst
  ELSE order_date_monthfirst
END AS order_date_clean
```
**Why this approach:** parsing `order_date` and `shipping_date` independently produced 27,643 false "shipped before ordered" cases — not real anomalies, but artifacts of picking mismatched conventions for the two columns on the same row (e.g. order parsed month-first, shipping parsed day-first). Requiring both dates on a row to use the *same* convention, and preferring whichever pairing keeps `shipping >= order`, resolved this to exactly 0 false positives, confirmed by re-running the ship-before-order check.

**Result:** `order_date_clean`/`shipping_date_clean` are `DATE` type, ~8.7%/8.8% NULL (genuinely unparseable junk, by design), 0 logical inconsistencies.

### Section B: Delivery / Status

**Problem — synonym collisions, not just casing.** `order_status` contained both `"cancelled"` and `"CANCELED"` (two spellings of the same status, 14,974 + 14,861 rows) — a plain `UPPER(TRIM())` would have produced two separate categories instead of merging them.

**Problem — junk substrings interfering with pattern matching.** `shipping_mode` values like `"Second Class<br>"` or `"standard classN/A - check later"` needed junk-stripping *before* pattern matching, or the trailing junk would prevent the `REGEXP_CONTAINS` match from firing.

```sql
CASE
  WHEN REGEXP_CONTAINS(UPPER(shipping_mode_stripped), r'STANDARD') THEN 'Standard Class'
  WHEN REGEXP_CONTAINS(UPPER(shipping_mode_stripped), r'FIRST')    THEN 'First Class'
  WHEN REGEXP_CONTAINS(UPPER(shipping_mode_stripped), r'2ND|SECOND') THEN 'Second Class'
  WHEN REGEXP_CONTAINS(UPPER(shipping_mode_stripped), r'SAME')     THEN 'Same Day'
  ELSE NULL
END AS shipping_mode_clean
```

**Validation cross-check:** since the generator derives `late_delivery_risk` purely from `real_shipping_days > scheduled_days_for_shipment`, cleaning both fields independently allowed a consistency check: **100% agreement across all 193,765 rows** where both day-count fields were non-null — confirming `late_delivery_risk_clean` needed no independent correction.

### Section C: Money / Quantity

**Problem — comma means two different things depending on context.** `"$1,504.42"` uses comma as a thousands separator; `"2256,63"` (no dollar sign) uses comma as the decimal point. A single `REPLACE(',', '')` would corrupt the second pattern.

```sql
CASE
  WHEN UPPER(TRIM(sales)) IN ('NONE','N/A','??','-','NULL') OR TRIM(sales) = '' THEN NULL
  WHEN sales LIKE '$%' THEN SAFE_CAST(REPLACE(REPLACE(TRIM(sales),'$',''),',','') AS FLOAT64)
  WHEN REGEXP_CONTAINS(sales, r',') THEN SAFE_CAST(REPLACE(TRIM(sales),',','.') AS FLOAT64)
  ELSE SAFE_CAST(TRIM(sales) AS FLOAT64)
END AS sales_clean
```

**Design decision — flag, don't drop, invalid quantities.** `order_item_quantity` values of `-1`/`0` are business-invalid but not unparseable; since they affect ~21% of rows, dropping them outright would meaningfully distort downstream LTV/funnel counts. They're kept and flagged via `is_quantity_invalid`, with mart views filtering explicitly (`WHERE NOT is_quantity_invalid`) wherever a valid quantity is required for a calculation.

### Section D: Segmentation Dimensions

**Problem — `order_country` variants are genuine spelling differences, not casing.** `USA`/`US`/`u.s.a.`/`United States` cannot be collapsed by `UPPER(TRIM())`; this required an explicit `CASE WHEN UPPER(TRIM(order_country)) IN (...)` mapping table per country, unlike `customer_segment`/`order_region`/`market`, which used pattern-matching against a stripped, upper-cased string.

**Validation:** post-cleaning, `order_country_clean` collapsed to exactly 7 canonical values with a balanced distribution (29,306–29,656 rows each) — confirming no cross-country mis-mapping occurred.

---

## Star Schema: Fact & Dimension Layer

**Files:** `sql/02_fact_order_item.sql` through `sql/06_data_validation.sql`

### Design decisions

- **Grain:** `fact_order_item` is one row per `order_item_id` (matches the dedup grain established in Section A).
- **Degenerate dimensions on the fact table, not `dim_customer`:** `order_region`, `order_state`, `order_country`, `market` describe the *order's* destination, which can vary shipment-to-shipment for the same customer. Placing them on `dim_customer` would incorrectly imply one fixed location per customer.
- **`dim_customer`'s segment uses "most recent," not `ANY_VALUE()`:**
  ```sql
  ARRAY_AGG(customer_segment_clean IGNORE NULLS ORDER BY order_date_clean DESC LIMIT 1)[SAFE_OFFSET(0)] AS customer_segment
  ```
  `ANY_VALUE()` would pick an arbitrary row's segment if it varies across a customer's order history (possible even for the same real customer, given the dirty source data); this instead deterministically picks the most recent non-null value.
- **Scope decision — `customer_city`/`state`/`country` and `product_price` carried as-is, not cleaned.** Neither is used by any of the four modules: order-level geography (already cleaned) is the geography of record for a logistics BD tool, and `order_item_product_price_clean` (transaction-time price) is the figure actually used in revenue calculations, making the product's base `product_price` redundant to clean.

### A late-discovered date-correction bug, and its fix

While building Module 3 (RFM), a `MIN(recency_days) = -130` surfaced — impossible, since the dataset's known ceiling is `2026-07-30`. Root cause: for rows where `shipping_date` was NULL, Section A's cross-referencing tie-breaker had no anchor, so the resolver fell back to a month-first default that was sometimes wrong (e.g. `"2026-12-07"` should have been July 12, not December 7 — December doesn't otherwise exist in the dataset).

**Fix, applied in `02_fact_order_item.sql`:** for any `order_date_clean`/`shipping_date_clean` value exceeding the known ceiling, attempt a day/month swap; if the swapped value is still invalid (day > 12, so no valid month interpretation exists) or still exceeds the ceiling after swapping, set to NULL rather than retain an impossible date.

```sql
CASE
  WHEN order_date_clean > '2026-07-30'
   AND EXTRACT(DAY FROM order_date_clean) <= 12
  THEN DATE(EXTRACT(YEAR FROM order_date_clean), EXTRACT(DAY FROM order_date_clean), EXTRACT(MONTH FROM order_date_clean))
  WHEN order_date_clean > '2026-07-30'
  THEN NULL
  ELSE order_date_clean
END AS order_date_final
```

**Scope:** 860 order-date rows and 5,199 shipping-date rows were affected (0.4%/2.4% of the fact table) — small enough that this was a targeted patch applied once, upstream in `fact_order_item`, rather than a full rebuild of Section A's logic.

### Validation (all confirmed)

| Check | Result |
|---|---|
| `fact_order_item` row count vs `stg_orders_final` | 219,571 = 219,571 |
| Orphaned `customer_id` / `product_card_id` / date keys | 0 / 0 / 0 |
| `dim_customer` rows vs distinct customers in fact | 8,000 = 8,000 |
| `dim_product` rows vs distinct products in fact | 500 = 500 |
| Post date-correction: rows with date > known ceiling | 0 / 0 |

---

## Mart Views: Module-by-Module Deep Dive

### Module 1 — `mart_funnel` (`sql/07`, validated in `sql/08`)

**Grain:** order-item level (not pre-aggregated) — since `order_status` was generated per-row independently, a single `order_id` can technically carry different statuses across its line items; keeping the grain at order-item level lets BI-layer measures (`COUNT(DISTINCT order_id)`) handle this correctly rather than pre-deciding an aggregation level in SQL.

**Stage definitions:**
```sql
TRUE AS is_placed,
CASE WHEN order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD') THEN TRUE ELSE FALSE END AS is_shipped,
CASE WHEN order_status IN ('COMPLETE', 'CLOSED') THEN TRUE ELSE FALSE END AS is_delivered,
CASE WHEN order_status IN ('COMPLETE', 'CLOSED') AND late_delivery_risk = 0 THEN TRUE ELSE FALSE END AS is_delivered_on_time
```

**Finding, and an honest null result:** late-delivery rate is flat (44.8%–46.1%) across every shipping mode and every region — tested via `GROUP BY shipping_mode`/`GROUP BY order_region` aggregate queries, not assumed. Root cause: in the generator, delay was derived purely from randomly-assigned `real_shipping_days` vs. `scheduled_days_for_shipment`, with no relationship to mode or region — so there is no real signal for any query to surface. Reported as-is rather than forcing a "Mode X is worse" narrative the data doesn't support.

### Module 2 — `mart_cohort` (`sql/09`, validated in `sql/10`)

**Grain:** one row per (`cohort_month`, `month_index`) — genuinely requires pre-aggregation, unlike Module 1.

**Right-censoring bug and fix:** an early version showed retention collapsing to ~1–3% at high `month_index` values (e.g. month 31+ for the earliest cohort) — not real churn, but a boundary artifact: the dataset only contains orders through 2026-07-30, so late month-indices for early cohorts have almost no observation window left. Fixed by filtering out any (cohort, month_index) pair whose target month isn't fully contained within the data window:
```sql
WHERE DATE_ADD(a.cohort_month, INTERVAL a.month_index MONTH) <= DATE_SUB('2026-07-30', INTERVAL 1 MONTH)
```
Confirmed fixed by inspecting the Jan 2024 cohort's tail, which now stops cleanly at month_index 29 (53.2% retention) instead of showing an artificial crash at month 30+.

**Finding:** retention drops from 100% (month 0) to ~58% (month 1), then plateaus in a noisy 50–60% band through month 12+ rather than continuing to decay — the loss is concentrated early, not ongoing.

### Module 3 — `mart_churn_rfm` (`sql/11`, validated in `sql/12`)

**Grain:** one row per `customer_id`. **Snapshot date:** `2026-07-30` (the data's known ceiling).

**RFM scoring — `NTILE(5)` over hardcoded thresholds:**
```sql
NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
NTILE(5) OVER (ORDER BY frequency ASC) AS f_score,
NTILE(5) OVER (ORDER BY monetary ASC) AS m_score
```
**Why quintiles, not fixed cutoffs:** the actual data distribution was checked first (median recency 27 days, tight frequency IQR of 22–28, wide monetary spread $3.7K–$104.9K) — `NTILE` auto-balances bucket sizes regardless of skew, which is more defensible than guessed thresholds, especially given frequency's narrow spread would make fixed cutoffs arbitrary.

**Segment thresholds** (RFM score, range 3–15): Growing ≥12, Stable ≥9, At Risk ≥6, Lapsed <6.

**Validation — internal consistency, not just distribution sanity:**
- `avg_monetary` declines **monotonically** across segments: Growing $60,669 → Stable $48,052 → At Risk $37,546 → Lapsed $29,497 — a strong signal the RFM score genuinely captures account value, not noise.
- `segment` vs. the simpler `is_churned` (90-day recency threshold) flag diverge in an expected, explainable way: churn rate rises correctly across segments (Growing 0% → Stable 9.5% → At Risk 18% → Lapsed 48.4%), but isn't 1:1, since `segment` blends three signals while `is_churned` uses only recency — a recently-active but low-frequency/low-value account can still land in "At Risk" by combined score.

### Module 4 — `mart_ltv` (`sql/13`, validated in `sql/14`)

**Grain:** one row per `customer_id`.

**Dominant-region/market attribution:** since a customer's orders can span multiple regions, each customer is attributed to their **most-frequent** region/market (tie-broken by most recent), not split proportionally — consistent with how `dim_customer`'s segment field is resolved, and matching how a real BD rep would think about account ownership ("where do we primarily do business with them").

```sql
ROW_NUMBER() OVER (
  PARTITION BY customer_id
  ORDER BY region_order_count DESC, latest_order_in_region DESC
) AS rn
```

**Two LTV formulas, cross-validated:**
```sql
-- Historical (simple sum)
SUM(sales) AS historical_ltv

-- Formula-based (AOV x frequency x lifespan)
(historical_ltv / total_orders) * (total_orders / lifespan_months) * lifespan_months AS formula_based_ltv
```
`CORR(historical_ltv, formula_based_ltv) = 1.0`, 0 mismatches — expected, since the formula reduces algebraically to the simple sum; this was a validity check on the calculation, not an independent finding.

**Finding, and an honest null result:** LTV is flat (~$44–46K) across both `customer_segment` and `dominant_region` — tested and ruled out, same pattern as Module 1. The genuine LTV signal lives in Module 3's RFM-segment breakdown instead: engagement level predicts value far better than firmographic segment or geography.

---

## Key Findings & Dashboard Layout

From **219,571** cleaned order-line records across **8,000** accounts:

| Module | Headline Number | Business Context |
|---|---|---|
| Funnel | 111,814 → 97,579 → 47,823 → 28,654 (placed → shipped → delivered → on-time) | Biggest leak is Shipped→Delivered (51% loss), not on-time performance |
| Cohort | ~58% retention at month 1, plateau ~50–60% through month 12+ | Retention risk is front-loaded to onboarding, not ongoing |
| Churn/RFM | 44.3% of accounts (3,547) At Risk/Lapsed; value declines monotonically Growing→Lapsed | Strongest, most actionable finding — ranked BD call list |
| LTV | Flat ~$44–46K by segment/region | Null result — engagement (Module 3) is the real value driver |

### Dashboard Layout

```
┌────────────────────────────────────────────────────────────────────────────────┐
│                    ACCOUNT HEALTH & GROWTH — CONTROL VIEW                       │
├────────────────────────────────────────────────────────────────────────────────┤
│ [FILTER BAR: Region | Segment | Date range]                                    │
├──────────────┬──────────────┬──────────────┬──────────────────────────────────┤
│ 44% accounts │ ~55%         │ ~45% late    │ 2.1x Growing vs Lapsed LTV        │
│ need attn.   │ retention    │ delivery     │                                    │
│              │ plateau      │ rate         │                                    │
├──────────────────────────────┬─────────────────────────────────────────────────┤
│ [Delivery Funnel]             │ [Cohort Retention Heatmap]                     │
│ Placed→Shipped→Delivered→     │ (Matrix: rows=cohort month, cols=month index,  │
│ On Time (native funnel visual)│  conditional-formatting color scale)           │
├────────────────────────────────────┬─────────────────────────────────────────┤
│ [Account Risk Segments Table]      │ [LTV by Engagement Segment]              │
│ Segment | Accounts | Avg LTV       │ (Clustered column: Growing→Lapsed)       │
└────────────────────────────────────┴─────────────────────────────────────────┘
```

---

## Recommendations

### 1. Prioritized BD Retention List (Immediate)
**Finding:** 3,547 accounts (44.3%) segmented At Risk or Lapsed, with average value ranging $29.5K–$37.5K.
**Action:** Filter `mart_churn_rfm` to `segment IN ('At Risk', 'Lapsed')`, sort by `monetary` descending, use directly as a BD outreach queue.

### 2. Reprioritize by Engagement, Not Firmographics (Immediate)
**Finding:** LTV is flat by customer segment and region, but varies 2.1x by RFM-derived engagement tier.
**Action:** Stop targeting BD effort by industry vertical or geography; target by engagement/RFM segment instead.

### 3. Front-Load Retention Effort to Onboarding (Operational)
**Finding:** Retention loss concentrates in month 0→1, then plateaus rather than continuing to decay.
**Action:** Invest in first-30-day onboarding touchpoints (check-in calls, proactive support) rather than late-stage win-back campaigns.

### 4. Investigate Order-Completion Friction, Not Just Lateness (Product/Ops)
**Finding:** 51% of shipped orders never reach "delivered" status — a bigger leak than the on-time/late split downstream of it.
**Action:** Break down `order_status` for shipped-but-not-delivered orders (cancellations vs. holds vs. stuck-in-processing) to find the actual driver.

### 5. Don't Chase Mode/Region-Specific Delivery Fixes on This Data (De-prioritize)
**Finding:** Late-delivery rate is uniform (44.8%–46.1%) across every shipping mode and region.
**Action:** Any reliability initiative should be treated as network-wide, not targeted at a specific carrier or lane, until further data suggests otherwise.

---

## Execution Guide

**Prerequisites:** Python 3.8+, a Google Cloud project with BigQuery enabled, Power BI Desktop (with the BigQuery connector).

### Step 1 — Clone & install
```bash
git clone https://github.com/ericgalbarn/logistics-account-analytics.git
cd end-to-end-logistics-analytics
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Step 2 — Generate the dataset (optional — already included)
```bash
python python/generate_dataset.py --rows 220000 --customers 8000 --products 500 --out dirty_supply_chain_dataset.csv
```
Expected: ~223,300 rows (220,000 base + ~1.5% injected exact duplicates), 53 columns.

### Step 3 — Load into BigQuery
Create a dataset (e.g. `logistic_analytics_dataset`) and load `dirty_supply_chain_dataset.csv` as `logistic_analytics_table`.

### Step 4 — Run the cleaning pipeline
```sql
-- sql/01_data_cleaning.sql, run top to bottom
-- Produces: stg_orders_deduped -> stg_orders_clean -> stg_orders_money_clean -> stg_orders_final
```
Expected: 219,571 final rows, ~8.7% NULL dates (by design), 0 logical date inconsistencies.

### Step 5 — Build the star schema
```sql
-- Run in order: 02_fact_order_item.sql, 03_dim_date.sql, 04_dim_customer.sql, 05_dim_product.sql
-- Then validate: 06_data_validation.sql
```
Expected: all referential integrity checks return 0 orphaned rows.

### Step 6 — Build the mart views
```sql
-- Run in order: 07, 09, 11, 13 (view creation), validating with 08, 10, 12, 14 after each
```

### Step 7 — Connect Power BI
Connect Power BI Desktop to BigQuery, import `mart_funnel`, `mart_cohort`, `mart_churn_rfm`, `mart_ltv`, `dim_customer`, `dim_date`. Build:
- Native **Funnel** visual on a small DAX summary table (`FunnelStages`)
- **Matrix** visual with conditional-formatting color scale for the cohort heatmap (requires a `RetentionRate` measure: `DIVIDE(SUM(mart_cohort[retention_pct]), 100)`, since the SQL column is already a 0–100 percentage, not a 0–1 fraction)
- **Table** visual for the risk segment breakdown
- **Clustered column** chart for LTV by segment
- **Card** visuals + slicers for the KPI/filter row

---

## Limitations & Assumptions

This project is transparent about its scope and constraints:

- **Synthetic data:** the working dataset is generated via Python (Faker-based) from the DataCo schema, with deliberately injected data-quality issues. No real customer or transaction data is used at any stage.
- **Cleaning scope was deliberately bounded.** Only the ~20 columns feeding the four analytical modules were cleaned (keys/IDs/dates, delivery/status, money/quantity, segmentation). Columns like `customer_email`, `customer_password`, `product_image`, `latitude`/`longitude`, and zip codes were left untouched — not an oversight, but a scoping decision made explicit up front, since none of the four modules depend on them.
- **Two of five headline findings are honest null results.** Late-delivery rate by shipping mode/region and LTV by customer segment/region both showed no meaningful variation — reported as tested-and-ruled-out rather than forced into a more dramatic (unsupported) narrative. This reflects a property of the synthetic data generator (these fields were assigned independently of the outcome variables), not necessarily a pattern that would hold on real operational data.
- **RFM thresholds were calibrated against the actual data distribution**, not guessed — but the specific cutoffs (12/9/6 for Growing/Stable/At Risk) are illustrative starting points that would need re-validation against a different dataset's distribution before reuse.
- **Date ambiguity has an irreducible floor.** Even after same-convention pairing resolved the vast majority of `MM/DD` vs `DD/MM` ambiguity, ~8.7% of rows have genuinely unparseable dates by design (intentional junk values) and are correctly left NULL rather than guessed.
- **No live/streaming component.** This pipeline runs as scheduled batch SQL against BigQuery, not a real-time system. The dashboard reflects a point-in-time snapshot, refreshed on demand.
- **Scope is Data Analytics/BI, not Machine Learning.** The current churn segmentation is rule-based (RFM), not a trained model — see Future Work for the planned logistic regression layer.

---

## Future Work

- **Logistic regression churn model** in Python (scikit-learn), using `recency_days`, `frequency`, `monetary`, and `avg_delivery_delay` (already computed in `mart_churn_rfm`) as features, to produce a probabilistic churn-risk score alongside the current rule-based RFM segment.
- **Root-cause breakdown of the Shipped→Delivered funnel drop-off** — joining `mart_funnel` against detailed `order_status` categories to separate cancellations, fraud holds, and processing delays, since the current funnel treats "not delivered" as one bucket.
- **Automated refresh + alerting** — BigQuery scheduled queries to refresh the mart views, paired with a Power Automate flow that detects accounts newly entering the At Risk/Lapsed segment and sends a summary notification, rather than relying on someone remembering to check the dashboard.
- **Account drill-through page** in Power BI — a single-account detail view (shipment volume trend, on-time delivery history, risk-score trend) triggered by clicking a row in the risk table, giving BD reps account-level detail without leaving the dashboard.
- **Filter cross-model relationships** — `mart_funnel` and `mart_cohort` currently sit at order-line and cohort-month grain respectively, which limits how cleanly region/date slicers can cross-filter them against the customer-grain `mart_churn_rfm`/`mart_ltv` views; a future iteration could add bridge tables to unify filtering across all four modules.