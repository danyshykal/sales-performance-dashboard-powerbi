# Build Guide — Sales Performance Dashboard (Power BI × Olist)

Do the steps in order and tick each ✅ checkpoint before moving on. If your numbers don't match, the bug is in that step.
Expect 8–12 hours, spread over a few sessions.

---

## Step 1 — Get the data

1. Download **Brazilian E-Commerce Public Dataset by Olist** from Kaggle (search the name, publisher: *Olist*). Licence: CC BY-NC-SA 4.0. Credit it in your README.
2. Unzip into this repo's `data/` folder, next to `DimState.csv` (already included).
3. You need these files (you can skip `olist_geolocation_dataset.csv` and `olist_order_payments_dataset.csv`):
   - `olist_orders_dataset.csv`, `olist_order_items_dataset.csv`, `olist_customers_dataset.csv`
   - `olist_products_dataset.csv`, `olist_sellers_dataset.csv`, `olist_order_reviews_dataset.csv`
   - `product_category_name_translation.csv`

> Add `data/*.csv` to `.gitignore` **except** `DimState.csv`. Link the Kaggle page in the README instead of committing ~120 MB of CSVs.

---

## Step 2 — Power Query

Open `powerquery/queries.pq` and follow the instructions at the top: create the `DataFolder` parameter, then make each query **in the given order**.

| Query | Load? | Problems it fixes |
|---|---|---|
| stg_Customers | ❌ staging | `customer_id` is a new ID **per order**. The real person is `customer_unique_id`. |
| stg_Reviews | ❌ staging | Some orders have 2+ reviews, so only the latest one is kept. Comments contain line breaks. |
| stg_CategoryTranslation | ❌ staging | — |
| FactOrders | ✅ | Empty delivery dates become nulls. Keeps only Jan 2017 – Aug 2018. Adds delivery days, on-time flag and the valid-order flag. |
| FactOrderItems | ✅ | Removes canceled/unavailable orders. Brings in order-level fields. |
| DimProduct | ✅ | Fixes typo columns (`lenght`), translates Portuguese categories to English, labels 610 products with no category as "Unknown", and fills in 2 categories that have no translation. |
| DimSeller | ✅ | Adds a short readable `SellerCode`, because the raw ID is a 32-character hash. |
| DimState | ✅ | Maps state code → state name → region. |

**Why the date window?** Sep–Dec 2016 has only ~330 orders (the platform was still ramping up) and Sep–Oct 2018 has 20 (the data stops there). Including them would distort trends and YoY. **Write this in your README.** It's a reasoned data decision, and interviewers love those.

**Why not use the payments table for revenue?** It has several rows per order (vouchers, instalments), so joining it to items would double-count. Revenue = item `price`.

✅ **Checkpoint:** FactOrders = **99,092** rows · FactOrderItems = **111,752** rows · DimProduct = 32,951 · DimSeller = 3,095 · DimState = 27

---

## Step 3 — Data model

1. Modeling → New table → paste `DimDate` from `dax/measures.dax` → **Mark as date table**. Sort `Month` by `MonthNo` and `MonthYear` by `MonthStart`.
2. Create the relationships (all **many-to-one, single direction**):

| From (many) | To (one) |
|---|---|
| FactOrderItems[OrderDate] | DimDate[Date] |
| FactOrderItems[product_id] | DimProduct[product_id] |
| FactOrderItems[seller_id] | DimSeller[seller_id] |
| FactOrderItems[customer_state] | DimState[StateCode] |
| FactOrders[OrderDate] | DimDate[Date] |
| FactOrders[customer_state] | DimState[StateCode] |

3. **Do NOT** relate FactOrders ↔ FactOrderItems directly. That creates ambiguous paths through DimDate. Two facts sharing dimensions is the correct design.
4. Hide the key columns in the fact tables. Set the DimState[StateName] / MapLocation data category to *State or Province* / *Place*.
5. Screenshot the model view as `docs/model.png`.

---

## Step 4 — Measures

1. Home → Enter Data → table `_Measures` → Load.
2. Create the **What-if parameter** first (see section 5 of `measures.dax`): `Target Growth`, 0–0.30, step 0.01, default **0.05**.
3. Create every measure in `dax/measures.dax` and assign display folders.
4. Formats: currency → `R$ #,0` (or `R$ #,0.00` for AOV); percentages → 1 decimal; review score → 2 decimals.

✅ **Checkpoint** (table visual with DimDate[Year], target growth = 5%):

| Measure | 2017 | 2018 (Jan–Aug) |
|---|---|---|
| Revenue | R$ 6,108,492 | R$ 7,341,037 |
| Freight Revenue | R$ 982,077 | R$ 1,252,100 |
| Total Orders | 44,375 | 53,530 |
| Items Sold | 50,617 | 61,135 |
| Avg Order Value | R$ 137.66 | R$ 137.14 |
| Active Customers | 43,030 | 52,336 |
| Active Sellers | 1,766 | 2,354 |
| Avg Review Score* | 4.11 | 4.10 |
| Negative Review %* | 13.8% | 14.6% |
| Avg Delivery Days | 12.98 | 12.06 |
| On-Time Delivery % | 94.4% | 92.3% |
| Cancellation Rate % | 1.6% | 0.9% |
| Revenue YoY % | — | +138.3% |
| Sales Target | R$ 4,531,053 (Apr–Dec) | R$ 7,613,072 |
| Target Achievement % | 118.6% | 96.4% |
| Months Target Hit | 8 of 9 | 4 of 8 |

No year filter: **Repeat Customer Rate ≈ 3.0%** · **Top 20% Seller Revenue Share ≈ 82.5%**

\*Kaggle has published two versions of the reviews file, so review numbers may differ by ±0.01. Everything else should match exactly.

**Common mistakes:**
- Revenue too high → canceled orders weren't removed, or you used the payments table.
- Customers ≈ orders → you counted `customer_id` instead of `customer_unique_id`.
- Total YoY shows ~+20% → DimDate runs past Aug 2018, or you didn't filter the date window.

---

## Step 5 — Report pages

Canvas 1280 × 720. One theme, max 3 brand colours. Use red/amber/green **only** for target status.

### Page 1 — Executive Overview
- Header: `Title Overview` + `Subtitle YoY` (dynamic text).
- Slicers: Year, Quarter, Region, Category.
- **KPI cards (Card new visual)**: Revenue, Total Orders, AOV, Active Customers, Avg Review Score, Target Achievement %. Add the YoY % as a reference label on each.
- **Line chart**: MonthYear → Revenue, Revenue LY, Revenue 3M Rolling Avg.
- **Filled map / Azure map**: Revenue by DimState[MapLocation].
- **Bar**: Top 10 categories by Revenue.

### Page 2 — Target vs Actual
- Put the **Target Growth slider** on this page. Moving it live is great in a demo.
- **Line & clustered column**: MonthYear → Revenue (columns), Sales Target (line).
- **Matrix**: rows = Region → StateName, columns = MonthYear (2018 only), values = Target Achievement %. Background colour = `KPI Status Colour` (field value).
- **Cards**: Target Achievement %, Target Variance, Months Target Hit / Months With Target.
- **Table**: Category | Revenue | Sales Target | Variance | `KPI Status`.

### Page 3 — Seller Performance
- **Table**: SellerCode | seller_state | Revenue | Orders | AOV | Avg Review Score | On-Time Delivery % | Seller Rank. Visual-level filter: Total Orders ≥ 30. Add data bars on Revenue.
- **Scatter**: X = Total Orders, Y = Avg Review Score, Size = Revenue, Details = SellerCode. Do big sellers keep quality up?
- **Card**: Top 20% Seller Revenue Share (Pareto).
- **Bar**: Active Sellers by seller_state.

### Page 4 — Customer Experience & Delivery
- **Column**: MonthYear → On-Time Delivery %, with Avg Delivery Days as a line.
- **Bar**: Avg Delivery Days by StateName (sorted). Which states wait longest?
- **Scatter by state**: X = Avg Delivery Days, Y = Avg Review Score. Does slow delivery hurt reviews?
- **Cards**: Negative Review %, Cancellation Rate %, Repeat Customer Rate %.

### Bonus (to stand out)
- **Drill-through** "Category Detail": monthly trend, top sellers and review score for one category.
- **Tooltip page** on the main line chart: Orders, AOV, YoY % for the hovered month.
- **Field parameter**: switch the main chart between Revenue / Orders / AOV / Customers.
- **Bookmarks** + a left-side page navigator.

---

## Step 6 — Insights (most important part)

Find **3–5 insights** and write each one as: **Finding → Evidence (a number from your dashboard) → Recommendation.**
Questions to investigate:
1. When did growth stall in 2018, and which states or categories caused the target misses?
2. What happened in Nov 2017 (hint: Black Friday), and how did it distort the targets for the following months?
3. How much do late deliveries drag down review scores? Compare on-time vs late orders.
4. How concentrated is revenue among the top sellers? Is that a risk?
5. Repeat rate is very low. What does that mean for a marketplace, and what would you suggest?

---

## Step 7 — Publish

1. Save as `Sales_Performance_Dashboard.pbix`.
2. Export each page as PNG into `screenshots/` (`01_overview.png` … `04_customer.png`). Record a 30–60 s GIF with ScreenToGif.
3. Optional: Power BI Service → *Publish to web* (needs a work/school account) → link it in the README.
4. Push to GitHub and pin the repo on your profile.
