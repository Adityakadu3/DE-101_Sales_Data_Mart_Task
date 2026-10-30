USE AdventureWorksLT2022;
GO

/*
Day 5 - Business Questions
Purpose: Answer the five business questions using the sales mart.
Before submitting, run each section and check the actual results.
*/

------------------------------------------------------------
-- QUESTION 1: Top 3 products by revenue in each category
------------------------------------------------------------
;WITH ProductRevenue AS
(
    -- First, calculate revenue once for each product.
    SELECT
        p.category_id,
        p.category_name,
        p.product_id,
        p.product_name,
        SUM(f.revenue) AS total_revenue
    FROM mart.fact_sales AS f
    INNER JOIN mart.dim_product AS p
        ON p.product_key = f.product_key
    GROUP BY
        p.category_id,
        p.category_name,
        p.product_id,
        p.product_name
),
RankedProducts AS
(
    -- DENSE_RANK gives tied revenue values the same rank.
    SELECT
        category_id,
        category_name,
        product_id,
        product_name,
        total_revenue,
        DENSE_RANK() OVER
        (
            PARTITION BY category_id
            ORDER BY total_revenue DESC
        ) AS revenue_rank
    FROM ProductRevenue
)
SELECT
    category_name,
    product_id,
    product_name,
    total_revenue,
    revenue_rank
FROM RankedProducts
WHERE revenue_rank <= 3
ORDER BY category_name, revenue_rank, product_name;
GO


------------------------------------------------------------
-- QUESTION 2: Each category's share of total revenue
------------------------------------------------------------
;WITH CategoryRevenue AS
(
    -- Add up sales revenue for each category.
    SELECT
        p.category_id,
        p.category_name,
        SUM(f.revenue) AS category_revenue
    FROM mart.fact_sales AS f
    INNER JOIN mart.dim_product AS p
        ON p.product_key = f.product_key
    GROUP BY p.category_id, p.category_name
)
SELECT
    category_name,
    category_revenue,

    -- OVER() calculates the total across all category rows.
    SUM(category_revenue) OVER () AS total_revenue,

    -- Multiply by 100 to express the category as a percentage.
    CAST(
        100.0 * category_revenue
        / NULLIF(SUM(category_revenue) OVER (), 0)
        AS DECIMAL(6,2)
    ) AS revenue_percentage
FROM CategoryRevenue
ORDER BY category_revenue DESC;
GO


------------------------------------------------------------
-- QUESTION 3: Customer Pareto and the 80% customer count
------------------------------------------------------------
;WITH CustomerRevenue AS
(
    -- Combine all sales for each real customer ID.
    -- The customer dimension may contain multiple historical rows,
    -- so group by customer_id rather than customer_key.
    SELECT
        c.customer_id,
        MAX(CASE WHEN c.is_current = 1 THEN c.customer_name END)
            AS customer_name,
        SUM(f.revenue) AS customer_revenue
    FROM mart.fact_sales AS f
    INNER JOIN mart.dim_customer AS c
        ON c.customer_key = f.customer_key
    GROUP BY c.customer_id
),
RunningRevenue AS
(
    SELECT
        customer_id,
        customer_name,
        customer_revenue,

        -- Give each customer a stable position, highest revenue first.
        ROW_NUMBER() OVER
        (
            ORDER BY customer_revenue DESC, customer_id
        ) AS customer_rank,

        -- Add this customer's revenue to all higher-ranked customers.
        SUM(customer_revenue) OVER
        (
            ORDER BY customer_revenue DESC, customer_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_revenue,

        -- Same overall revenue value on every customer row.
        SUM(customer_revenue) OVER () AS total_revenue
    FROM CustomerRevenue
),
Pareto AS
(
    SELECT
        customer_id,
        customer_name,
        customer_revenue,
        customer_rank,
        running_revenue,
        CAST(
            100.0 * running_revenue / NULLIF(total_revenue, 0)
            AS DECIMAL(6,2)
        ) AS running_revenue_percentage
    FROM RunningRevenue
)
SELECT
    customer_id,
    customer_name,
    customer_revenue,
    customer_rank,
    running_revenue,
    running_revenue_percentage,

    -- This value repeats on each row and tells how many top customers
    -- are needed to reach or pass 80% of revenue.
    MIN(CASE WHEN running_revenue_percentage >= 80
             THEN customer_rank END) OVER ()
        AS customers_needed_for_80_percent
FROM Pareto
ORDER BY customer_rank;
GO



-- QUESTION 4: Rank each customer's revenue within their country
------------------------------------------------------------
;WITH CustomerRevenue AS
(
    -- Calculate revenue across all historical dimension versions.
    SELECT
        c.customer_id,
        MAX(CASE WHEN c.is_current = 1 THEN c.customer_name END)
            AS customer_name,
        MAX(CASE WHEN c.is_current = 1 THEN c.country END)
            AS country,
        SUM(f.revenue) AS customer_revenue
    FROM mart.fact_sales AS f
    INNER JOIN mart.dim_customer AS c
        ON c.customer_key = f.customer_key
    GROUP BY c.customer_id
)
SELECT
    customer_id,
    customer_name,
    country,
    customer_revenue,

    -- Restart ranking separately for each country.
    DENSE_RANK() OVER
    (
        PARTITION BY country
        ORDER BY customer_revenue DESC
    ) AS country_revenue_rank
FROM CustomerRevenue
ORDER BY country, country_revenue_rank, customer_name;
GO


-- -- QUESTION 5A: Check source order-date coverage first
------------------------------------------------------------
-- Run this section before monthly analysis.
-- If the dates cover only one month, month-over-month analysis
-- cannot be meaningfully answered from this source.
SELECT
    MIN(OrderDate) AS earliest_order_date,
    MAX(OrderDate) AS latest_order_date,
    COUNT(DISTINCT CONVERT(date, OrderDate)) AS distinct_order_dates,
    COUNT(*) AS total_orders
FROM SalesLT.SalesOrderHeader;
GO


------------------------------------------------------------
-- QUESTION 5B: Month-over-month revenue and 3-month average
------------------------------------------------------------
-- This query uses the date dimension already connected to the mart.
-- Run it only after confirming the mart contains usable dates across
-- multiple months. A three-month average means the current month and
-- the previous two calendar months.

;WITH MonthlyRevenue AS
(
    SELECT
        DATEFROMPARTS(YEAR(d.[date]), MONTH(d.[date]), 1) AS sales_month,
        SUM(f.revenue) AS monthly_revenue
    FROM mart.fact_sales AS f
    INNER JOIN mart.dim_date AS d
        ON d.date_key = f.date_key
    GROUP BY
        DATEFROMPARTS(YEAR(d.[date]), MONTH(d.[date]), 1)
),
MonthlyMetrics AS
(
    SELECT
        sales_month,
        monthly_revenue,
        LAG(monthly_revenue) OVER (
            ORDER BY sales_month
        ) AS previous_month_revenue,
        AVG(monthly_revenue) OVER (
            ORDER BY sales_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS three_month_moving_average
    FROM MonthlyRevenue
)
SELECT
    sales_month,
    monthly_revenue,
    previous_month_revenue,
    monthly_revenue - previous_month_revenue AS revenue_change,
    CAST(
        100.0 * (monthly_revenue - previous_month_revenue)
        / NULLIF(previous_month_revenue, 0)
        AS DECIMAL(8,2)
    ) AS revenue_change_percentage,
    CAST(three_month_moving_average AS DECIMAL(18,2))
        AS three_month_moving_average
FROM MonthlyMetrics
ORDER BY sales_month;


--- PRACTICE



/*
    Day 5B - Question 1
    Find the top 3 products by revenue within each category.

    DENSE_RANK assigns the same rank when products have equal revenue.
*/

WITH ProductRevenue AS
(
    SELECT
        mart.dim_product.product_key,
        mart.dim_product.product_name,
        mart.dim_product.category_name,
        SUM(mart.fact_sales.revenue) AS total_revenue
    FROM mart.fact_sales
    INNER JOIN mart.dim_product
        ON mart.fact_sales.product_key =
           mart.dim_product.product_key
    GROUP BY
        mart.dim_product.product_key,
        mart.dim_product.product_name,
        mart.dim_product.category_name
),
RankedProducts AS
(
    SELECT
        product_key,
        product_name,
        category_name,
        total_revenue,
        DENSE_RANK() OVER
        (
            PARTITION BY category_name
            ORDER BY total_revenue DESC
        ) AS revenue_rank
    FROM ProductRevenue
)
SELECT
    category_name,
    product_name,
    total_revenue,
    revenue_rank
FROM RankedProducts
WHERE revenue_rank <= 3
ORDER BY
    category_name,
    revenue_rank,
    product_name;
GO




/*
    Day 5B - Question 2
    Business question:
    Calculate each product category's share of total revenue.

    SUM() OVER() calculates the overall revenue without
    grouping the result into a single row.
*/

WITH CategoryRevenue AS
(
    SELECT
        mart.dim_product.category_name,
        SUM(mart.fact_sales.revenue) AS category_revenue
    FROM mart.fact_sales
    INNER JOIN mart.dim_product
        ON mart.fact_sales.product_key =
           mart.dim_product.product_key
    GROUP BY
        mart.dim_product.category_name
)
SELECT
    category_name,
    category_revenue,
    SUM(category_revenue) OVER () AS total_revenue,
    CAST(
        category_revenue * 100.0
        / NULLIF(SUM(category_revenue) OVER (), 0)
        AS DECIMAL(10, 2)
    ) AS revenue_percentage
FROM CategoryRevenue
ORDER BY category_revenue DESC;
GO



/*
    Day 5B - Question 3
    Business question:
    Calculate the running percentage of revenue by customer
    and identify how many customers account for 80% of revenue.
*/

WITH CustomerRevenue AS
(
    SELECT
        mart.dim_customer.customer_id,
        SUM(mart.fact_sales.revenue) AS customer_revenue
    FROM mart.fact_sales
    INNER JOIN mart.dim_customer
        ON mart.fact_sales.customer_key =
           mart.dim_customer.customer_key
    WHERE mart.dim_customer.is_current = 1
    GROUP BY
        mart.dim_customer.customer_id
),
CustomerRunningRevenue AS
(
    SELECT
        customer_id,
        customer_revenue,
        SUM(customer_revenue) OVER
        (
            ORDER BY customer_revenue DESC, customer_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_revenue,
        SUM(customer_revenue) OVER () AS total_revenue,
        ROW_NUMBER() OVER
        (
            ORDER BY customer_revenue DESC, customer_id
        ) AS customer_rank
    FROM CustomerRevenue
),
CustomerPareto AS
(
    SELECT
        customer_id,
        customer_revenue,
        running_revenue,
        total_revenue,
        customer_rank,
        CAST(
            running_revenue * 100.0
            / NULLIF(total_revenue, 0)
            AS DECIMAL(10, 2)
        ) AS running_revenue_percentage
    FROM CustomerRunningRevenue
)
SELECT
    customer_id,
    customer_revenue,
    running_revenue,
    running_revenue_percentage,
    customer_rank
FROM CustomerPareto
ORDER BY customer_rank;
GO

/*
    Count how many customers are needed to reach 80% of revenue.
    Include the customer whose addition first reaches or exceeds 80%.
*/
WITH CustomerRevenue AS
(
    SELECT
        mart.dim_customer.customer_id,
        SUM(mart.fact_sales.revenue) AS customer_revenue
    FROM mart.fact_sales
    INNER JOIN mart.dim_customer
        ON mart.fact_sales.customer_key =
           mart.dim_customer.customer_key
    WHERE mart.dim_customer.is_current = 1
    GROUP BY
        mart.dim_customer.customer_id
),
CustomerRunningRevenue AS
(
    SELECT
        customer_id,
        customer_revenue,
        SUM(customer_revenue) OVER
        (
            ORDER BY customer_revenue DESC, customer_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_revenue,
        SUM(customer_revenue) OVER () AS total_revenue,
        ROW_NUMBER() OVER
        (
            ORDER BY customer_revenue DESC, customer_id
        ) AS customer_rank
    FROM CustomerRevenue
)
SELECT
    MIN(customer_rank) AS customers_needed_for_80_percent
FROM CustomerRunningRevenue
WHERE running_revenue >= total_revenue * 0.80;
GO




/*
    Day 5B - Question 4
    Business question:
    Rank each customer by revenue within their country.

    RANK assigns the same rank to customers with equal revenue.
    PARTITION BY country restarts the ranking for each country.
*/

WITH CustomerRevenue AS
(
    SELECT
        mart.dim_customer.customer_id,
        mart.dim_customer.country,
        SUM(mart.fact_sales.revenue) AS customer_revenue
    FROM mart.fact_sales
    INNER JOIN mart.dim_customer
        ON mart.fact_sales.customer_key =
           mart.dim_customer.customer_key
    WHERE mart.dim_customer.is_current = 1
    GROUP BY
        mart.dim_customer.customer_id,
        mart.dim_customer.country
)
SELECT
    country,
    customer_id,
    customer_revenue,
    RANK() OVER
    (
        PARTITION BY country
        ORDER BY customer_revenue DESC
    ) AS country_revenue_rank
FROM CustomerRevenue
ORDER BY
    country,
    country_revenue_rank,
    customer_id;
GO



/*
    Day 5B - Question 5
    Business question:
    Calculate month-over-month revenue change and
    a 3-month moving average.

    Limitation:
    AdventureWorksLT2022 currently contains orders
    from only one distinct month.
*/

USE AdventureWorksLT2022;
GO

SELECT
    YEAR(SalesLT.SalesOrderHeader.OrderDate) AS sales_year,
    MONTH(SalesLT.SalesOrderHeader.OrderDate) AS sales_month,
    SUM(SalesLT.SalesOrderHeader.SubTotal) AS monthly_revenue,
    COUNT(DISTINCT SalesLT.SalesOrderHeader.OrderDate)
        AS distinct_order_dates
FROM SalesLT.SalesOrderHeader
GROUP BY
    YEAR(SalesLT.SalesOrderHeader.OrderDate),
    MONTH(SalesLT.SalesOrderHeader.OrderDate)
ORDER BY
    sales_year,
    sales_month;
GO




















/* ============================================================================
   DE-101  |  05_business_questions.sql  |  Question 5 only
   Month-over-month (MoM) revenue change and 3-month moving average

   Step 1  Check the order dates in the source (AdventureWorksLT2022)
   Step 2  If the source cannot answer, use AdventureWorksDW2022.FactInternetSales
   Revenue definition: sum of line revenue, excluding tax and freight
     - LT : SalesOrderDetail.LineTotal   (as in the mart)
     - DW : FactInternetSales.SalesAmount (also excludes tax and freight)
   ============================================================================ */


/* ---------------------------------------------------------------------------
   STEP 1: Can the source answer a monthly-trend question?
   Needs at least 4 distinct months (3 for a full moving-average window + 1 for MoM).
   --------------------------------------------------------------------------- */
SELECT COUNT(*)                                                      AS total_orders,
       MIN(OrderDate)                                                AS first_order,
       MAX(OrderDate)                                                AS last_order,
       COUNT(DISTINCT OrderDate)                                     AS distinct_order_dates,
       COUNT(DISTINCT DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1)) AS distinct_months,
       CASE WHEN COUNT(DISTINCT DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1)) >= 4
            THEN 'Source can answer'
            ELSE 'Source CANNOT answer: use AdventureWorksDW' END    AS verdict
FROM AdventureWorksLT2022.SalesLT.SalesOrderHeader;
GO


/* ---------------------------------------------------------------------------
   STEP 2a: Profile the DW order dates before trusting them
   Shows the date range, and whether any calendar month is missing
   (a missing month would make LAG() compare against the wrong month).
   --------------------------------------------------------------------------- */
SELECT MIN(OrderDate) AS first_order,
       MAX(OrderDate) AS last_order,
       COUNT(*)       AS order_lines,
       COUNT(DISTINCT DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1)) AS distinct_months,
       DATEDIFF(MONTH, MIN(OrderDate), MAX(OrderDate)) + 1                 AS expected_months   -- equal => no gaps
FROM AdventureWorksDW2022.dbo.FactInternetSales;
GO


/* ---------------------------------------------------------------------------
   STEP 2b: Month-over-month change + 3-month moving average
   --------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT  DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1) AS month_start,
            SUM(SalesAmount)                                    AS revenue,
            MIN(OrderDate)                                      AS first_day_with_sales,
            MAX(OrderDate)                                      AS last_day_with_sales
    FROM    AdventureWorksDW2022.dbo.FactInternetSales
    GROUP BY DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1)
),
calc AS (
    SELECT  month_start,
            revenue,
            LAG(revenue) OVER (ORDER BY month_start)            AS prev_month_revenue,
            AVG(revenue) OVER (ORDER BY month_start
                               ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS moving_avg_3m_raw,
            COUNT(*)     OVER (ORDER BY month_start
                               ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS months_in_window,
            -- first and last month of the data are usually incomplete months
            CASE WHEN month_start = MIN(month_start) OVER ()
                   OR month_start = MAX(month_start) OVER ()
                 THEN 1 ELSE 0 END                              AS is_edge_month,
            first_day_with_sales,
            last_day_with_sales
    FROM    monthly
)
SELECT  month_start,
        CAST(revenue AS DECIMAL(18,2))                                   AS revenue,
        CAST(revenue - prev_month_revenue AS DECIMAL(18,2))              AS mom_change,
        CAST(100.0 * (revenue - prev_month_revenue)
                   / NULLIF(prev_month_revenue, 0) AS DECIMAL(9,2))      AS mom_change_pct,
        -- only show the average when the window really holds 3 months
        CASE WHEN months_in_window = 3
             THEN CAST(moving_avg_3m_raw AS DECIMAL(18,2)) END           AS moving_avg_3m,
        is_edge_month,
        first_day_with_sales,
        last_day_with_sales
FROM    calc
ORDER BY month_start;
GO