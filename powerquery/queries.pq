// =====================================================================
//  Power Query (M) — Sales Performance Dashboard (Olist)
//
//  HOW TO USE
//  1. Home → Manage Parameters → New Parameter
//       Name: DataFolder   Type: Text
//       Current value: the folder holding the CSVs, WITH trailing slash
//       e.g.  C:\Projects\sales-dashboard\data\
//  2. For each query below: Home → New Source → Blank Query →
//     Advanced Editor → paste → rename the query to the name shown.
//  3. Queries marked [STAGING] → right-click → untick "Enable load".
//  4. Create them in THIS ORDER (later queries reference earlier ones).
// =====================================================================


// ---------------------------------------------------------------------
// stg_Customers   [STAGING]
// customer_id is unique PER ORDER in Olist. customer_unique_id is the
// real person → needed for customer counts & repeat-customer rate.
// ---------------------------------------------------------------------
let
    Source   = Csv.Document(File.Contents(DataFolder & "olist_customers_dataset.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Selected = Table.SelectColumns(Promoted, {"customer_id", "customer_unique_id", "customer_state"})
in
    Selected


// ---------------------------------------------------------------------
// stg_Reviews   [STAGING]
// Some orders have more than one review → keep only the latest answer.
// (Review comments contain line breaks — QuoteStyle.Csv handles that.)
// ---------------------------------------------------------------------
let
    Source   = Csv.Document(File.Contents(DataFolder & "olist_order_reviews_dataset.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Selected = Table.SelectColumns(Promoted, {"order_id", "review_score", "review_answer_timestamp"}),
    Typed    = Table.TransformColumnTypes(Selected, {{"review_score", Int64.Type}, {"review_answer_timestamp", type datetime}}, "en-US"),
    Sorted   = Table.Buffer(Table.Sort(Typed, {{"order_id", Order.Ascending}, {"review_answer_timestamp", Order.Descending}})),
    Latest   = Table.Distinct(Sorted, {"order_id"}),
    Result   = Table.SelectColumns(Latest, {"order_id", "review_score"})
in
    Result


// ---------------------------------------------------------------------
// stg_CategoryTranslation   [STAGING]
// ---------------------------------------------------------------------
let
    Source   = Csv.Document(File.Contents(DataFolder & "product_category_name_translation.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true])
in
    Promoted


// ---------------------------------------------------------------------
// FactOrders   (1 row per order — used for cancellation / order status)
// ---------------------------------------------------------------------
let
    Source    = Csv.Document(File.Contents(DataFolder & "olist_orders_dataset.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted  = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    // Undelivered orders have empty delivery timestamps → make them real nulls
    Blanks    = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue,
                    {"order_approved_at", "order_delivered_carrier_date", "order_delivered_customer_date"}),
    Typed     = Table.TransformColumnTypes(Blanks, {
                    {"order_purchase_timestamp", type datetime},
                    {"order_delivered_customer_date", type datetime},
                    {"order_estimated_delivery_date", type datetime}}, "en-US"),
    AddDate   = Table.AddColumn(Typed,   "OrderDate",     each Date.From([order_purchase_timestamp]), type date),
    AddDeliv  = Table.AddColumn(AddDate, "DeliveredDate", each Date.From([order_delivered_customer_date]), type date),
    AddEst    = Table.AddColumn(AddDeliv,"EstimatedDate", each Date.From([order_estimated_delivery_date]), type date),
    // Sep–Dec 2016 and Sep–Oct 2018 have almost no orders (platform ramp-up / data cut-off)
    InWindow  = Table.SelectRows(AddEst, each [OrderDate] >= #date(2017, 1, 1) and [OrderDate] <= #date(2018, 8, 31)),
    JoinCust  = Table.NestedJoin(InWindow, {"customer_id"}, stg_Customers, {"customer_id"}, "c", JoinKind.LeftOuter),
    ExpCust   = Table.ExpandTableColumn(JoinCust, "c", {"customer_unique_id", "customer_state"}),
    JoinRev   = Table.NestedJoin(ExpCust, {"order_id"}, stg_Reviews, {"order_id"}, "r", JoinKind.LeftOuter),
    ExpRev    = Table.ExpandTableColumn(JoinRev, "r", {"review_score"}, {"ReviewScore"}),
    AddValid  = Table.AddColumn(ExpRev, "IsValid", each not List.Contains({"canceled", "unavailable"}, [order_status]), type logical),
    AddDays   = Table.AddColumn(AddValid, "DeliveryDays",
                    each if [DeliveredDate] = null then null else Duration.Days([DeliveredDate] - [OrderDate]), Int64.Type),
    AddOnTime = Table.AddColumn(AddDays, "IsOnTime",
                    each if [DeliveredDate] = null then null else if [DeliveredDate] <= [EstimatedDate] then 1 else 0, Int64.Type),
    Final     = Table.SelectColumns(AddOnTime, {"order_id", "customer_unique_id", "customer_state", "order_status",
                    "OrderDate", "DeliveredDate", "EstimatedDate", "DeliveryDays", "IsOnTime", "ReviewScore", "IsValid"})
in
    Final


// ---------------------------------------------------------------------
// FactOrderItems   (1 row per item — MAIN fact table for revenue)
// Revenue = item price (excl. freight). Payments table is NOT used for
// revenue: it has multiple rows per order (vouchers / instalments) and
// would double-count.
// ---------------------------------------------------------------------
let
    Source    = Csv.Document(File.Contents(DataFolder & "olist_order_items_dataset.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted  = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Typed     = Table.TransformColumnTypes(Promoted, {{"order_item_id", Int64.Type}, {"price", Currency.Type}, {"freight_value", Currency.Type}}, "en-US"),
    JoinOrd   = Table.NestedJoin(Typed, {"order_id"}, FactOrders, {"order_id"}, "o", JoinKind.Inner),
    ExpOrd    = Table.ExpandTableColumn(JoinOrd, "o",
                    {"OrderDate", "customer_unique_id", "customer_state", "order_status", "IsValid", "DeliveryDays", "IsOnTime", "ReviewScore"}),
    ValidOnly = Table.SelectRows(ExpOrd, each [IsValid] = true),   // drop canceled / unavailable
    Final     = Table.RemoveColumns(ValidOnly, {"IsValid", "shipping_limit_date"}, MissingField.Ignore)
in
    Final


// ---------------------------------------------------------------------
// DimProduct
// Fixes: typo column names, Portuguese → English categories,
// 610 products with no category, 2 categories missing a translation.
// ---------------------------------------------------------------------
let
    Source   = Csv.Document(File.Contents(DataFolder & "olist_products_dataset.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Renamed  = Table.RenameColumns(Promoted, {{"product_name_lenght", "product_name_length"}, {"product_description_lenght", "product_description_length"}}),
    Blanks   = Table.ReplaceValue(Renamed, "", null, Replacer.ReplaceValue, {"product_category_name"}),
    JoinT    = Table.NestedJoin(Blanks, {"product_category_name"}, stg_CategoryTranslation, {"product_category_name"}, "t", JoinKind.LeftOuter),
    ExpT     = Table.ExpandTableColumn(JoinT, "t", {"product_category_name_english"}),
    AddCat   = Table.AddColumn(ExpT, "Category", each
                   if [product_category_name] = null then "Unknown"
                   else if [product_category_name] = "pc_gamer" then "Pc Gamer"
                   else if [product_category_name] = "portateis_cozinha_e_preparadores_de_alimentos" then "Portable Kitchen Appliances"
                   else Text.Proper(Text.Replace([product_category_name_english], "_", " ")), type text),
    Final    = Table.SelectColumns(AddCat, {"product_id", "Category", "product_category_name"})
in
    Final


// ---------------------------------------------------------------------
// DimSeller
// seller_id is a 32-char hash → add a short readable code for visuals.
// ---------------------------------------------------------------------
let
    Source   = Csv.Document(File.Contents(DataFolder & "olist_sellers_dataset.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    AddCode  = Table.AddColumn(Promoted, "SellerCode", each "S-" & Text.Upper(Text.Start([seller_id], 8)), type text),
    City     = Table.TransformColumns(AddCode, {{"seller_city", Text.Proper, type text}}),
    Final    = Table.SelectColumns(City, {"seller_id", "SellerCode", "seller_city", "seller_state"})
in
    Final


// ---------------------------------------------------------------------
// DimState   (lookup file included in this repo: data/DimState.csv)
// ---------------------------------------------------------------------
let
    Source   = Csv.Document(File.Contents(DataFolder & "DimState.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    AddMap   = Table.AddColumn(Promoted, "MapLocation", each [StateName] & ", Brazil", type text)
in
    AddMap
