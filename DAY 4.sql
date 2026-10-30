
/*
=============================================================
Day 4: Data Quality Checks
Database: AdventureWorksLT2022
Schema: SalesLT and mart

Purpose:
1. Validate fact table row count.
2. Reconcile fact revenue with source order header subtotal.
3. Check missing dimension keys (orphan records).
4. Check duplicate business keys in current dimensions.
5. Check customers with multiple current records.
6. Verify rerunning the stored procedure does not change
   dimension and fact table row counts.
7. Reconcile fact revenue with source order detail LineTotal.

Important:
The source header subtotal and detail line totals already
differ in this database. This script reports that discrepancy.
=============================================================
*/

USE AdventureWorksLT2022;
GO

SET NOCOUNT ON;

-------------------------------------------------------------
-- STEP 1: Create the results table
-- All checks will insert their results into this table.
-------------------------------------------------------------

IF OBJECT_ID('tempdb..#DQResults') IS NOT NULL
    DROP TABLE #DQResults;

CREATE TABLE #DQResults
(
    check_name VARCHAR(150),
    expected   VARCHAR(200),
    actual     VARCHAR(500),
    pass_fail  VARCHAR(10)
);

-------------------------------------------------------------
-- STEP 2: Check fact row count
-- Every source SalesOrderDetail row should have one fact row.
-------------------------------------------------------------

DECLARE @SourceDetailCount BIGINT;
DECLARE @FactRowCount BIGINT;

SELECT @SourceDetailCount = COUNT_BIG(*)
FROM SalesLT.SalesOrderDetail;

SELECT @FactRowCount = COUNT_BIG(*)
FROM mart.fact_sales;

INSERT INTO #DQResults
    (check_name, expected, actual, pass_fail)
VALUES
(
    'Fact row count',
    CAST(@SourceDetailCount AS VARCHAR(200)),
    CAST(@FactRowCount AS VARCHAR(500)),
    CASE
        WHEN @SourceDetailCount = @FactRowCount
        THEN 'PASS'
        ELSE 'FAIL'
    END
);

-------------------------------------------------------------
-- STEP 3: Reconcile fact revenue with source header subtotal
-- This is the original assignment check.
-- It may FAIL because the source totals do not match.
-------------------------------------------------------------

DECLARE @HeaderSubtotal DECIMAL(18,2);
DECLARE @FactRevenue DECIMAL(18,2);
DECLARE @HeaderDifference DECIMAL(18,2);

SELECT @HeaderSubtotal =
    SUM(CAST(SubTotal AS DECIMAL(18,2)))
FROM SalesLT.SalesOrderHeader;

SELECT @FactRevenue =
    SUM(CAST(revenue AS DECIMAL(18,2)))
FROM mart.fact_sales;

SET @HeaderDifference = @HeaderSubtotal - @FactRevenue;

INSERT INTO #DQResults
    (check_name, expected, actual, pass_fail)
VALUES
(
    'Header subtotal vs fact revenue',
    'Difference = 0.00',
    CONCAT(
        'Header subtotal = ', FORMAT(@HeaderSubtotal, 'N2'),
        '; Fact revenue = ', FORMAT(@FactRevenue, 'N2'),
        '; Difference = ', FORMAT(@HeaderDifference, 'N2')
    ),
    CASE
        WHEN ABS(@HeaderDifference) <= 0.01
        THEN 'PASS'
        ELSE 'FAIL'
    END
);

-------------------------------------------------------------
-- STEP 4: Check orphan dimension keys
-- Every fact row must match a date, customer and product key.
-------------------------------------------------------------

DECLARE @OrphanCount BIGINT;

SELECT @OrphanCount = COUNT_BIG(*)
FROM mart.fact_sales AS fact
LEFT JOIN mart.dim_date AS date_dimension
    ON fact.date_key = date_dimension.date_key
LEFT JOIN mart.dim_customer AS customer_dimension
    ON fact.customer_key = customer_dimension.customer_key
LEFT JOIN mart.dim_product AS product_dimension
    ON fact.product_key = product_dimension.product_key
WHERE date_dimension.date_key IS NULL
   OR customer_dimension.customer_key IS NULL
   OR product_dimension.product_key IS NULL;

INSERT INTO #DQResults
    (check_name, expected, actual, pass_fail)
VALUES
(
    'Fact rows with missing dimension keys',
    '0',
    CAST(@OrphanCount AS VARCHAR(500)),
    CASE
        WHEN @OrphanCount = 0 THEN 'PASS'
        ELSE 'FAIL'
    END
);

-------------------------------------------------------------
-- STEP 5: Check duplicate business keys in current dimensions
-- Current customer records should have unique customer IDs.
-- Product business IDs should also be unique.
-------------------------------------------------------------

DECLARE @DuplicateCustomerCount BIGINT;
DECLARE @DuplicateProductCount BIGINT;

SELECT @DuplicateCustomerCount = COUNT_BIG(*)
FROM
(
    SELECT customer_id
    FROM mart.dim_customer
    WHERE is_current = 1
    GROUP BY customer_id
    HAVING COUNT(*) > 1
) AS duplicate_customers;

SELECT @DuplicateProductCount = COUNT_BIG(*)
FROM
(
    SELECT product_id
    FROM mart.dim_product
    GROUP BY product_id
    HAVING COUNT(*) > 1
) AS duplicate_products;

INSERT INTO #DQResults
    (check_name, expected, actual, pass_fail)
VALUES
(
    'Duplicate current customer business keys',
    '0',
    CAST(@DuplicateCustomerCount AS VARCHAR(500)),
    CASE
        WHEN @DuplicateCustomerCount = 0 THEN 'PASS'
        ELSE 'FAIL'
    END
);

INSERT INTO #DQResults
    (check_name, expected, actual, pass_fail)
VALUES
(
    'Duplicate product business keys',
    '0',
    CAST(@DuplicateProductCount AS VARCHAR(500)),
    CASE
        WHEN @DuplicateProductCount = 0 THEN 'PASS'
        ELSE 'FAIL'
    END
);

-------------------------------------------------------------
-- STEP 6: Check customers with multiple current records
-- Each customer should have no more than one current version.
-------------------------------------------------------------

DECLARE @MultipleCurrentCustomers BIGINT;

SELECT @MultipleCurrentCustomers = COUNT_BIG(*)
FROM
(
    SELECT customer_id
    FROM mart.dim_customer
    WHERE is_current = 1
    GROUP BY customer_id
    HAVING COUNT(*) > 1
) AS multiple_current_customers;

INSERT INTO #DQResults
    (check_name, expected, actual, pass_fail)
VALUES
(
    'Customers with multiple current records',
    '0',
    CAST(@MultipleCurrentCustomers AS VARCHAR(500)),
    CASE
        WHEN @MultipleCurrentCustomers = 0 THEN 'PASS'
        ELSE 'FAIL'
    END
);

-------------------------------------------------------------
-- STEP 7: Check fact revenue against source detail LineTotal
-- This is the like-for-like revenue reconciliation.
-- A small difference can occur because fact revenue is rounded.
-------------------------------------------------------------

DECLARE @SourceDetailRevenue DECIMAL(18,4);
DECLARE @FactRevenueDetailCheck DECIMAL(18,4);
DECLARE @DetailRevenueDifference DECIMAL(18,4);

SELECT @SourceDetailRevenue =
    SUM(CAST(LineTotal AS DECIMAL(18,4)))
FROM SalesLT.SalesOrderDetail;

SELECT @FactRevenueDetailCheck =
    SUM(CAST(revenue AS DECIMAL(18,4)))
FROM mart.fact_sales;

SET @DetailRevenueDifference =
    @SourceDetailRevenue - @FactRevenueDetailCheck;

INSERT INTO #DQResults
    (check_name, expected, actual, pass_fail)
VALUES
(
    'Source detail LineTotal vs fact revenue',
    'Difference <= 0.01',
    CONCAT(
        'Source detail = ', FORMAT(@SourceDetailRevenue, 'N4'),
        '; Fact revenue = ', FORMAT(@FactRevenueDetailCheck, 'N4'),
        '; Difference = ', FORMAT(@DetailRevenueDifference, 'N4')
    ),
    CASE
        WHEN ABS(@DetailRevenueDifference) <= 0.01
        THEN 'PASS'
        ELSE 'FAIL'
    END
);

-------------------------------------------------------------
-- STEP 8: Test stored procedure rerun
-- Capture row counts before and after running the procedure.
-- load_log is excluded because a new log row is expected.
-------------------------------------------------------------

DECLARE @DateCountBefore BIGINT;
DECLARE @DateCountAfter BIGINT;
DECLARE @ProductCountBefore BIGINT;
DECLARE @ProductCountAfter BIGINT;
DECLARE @CustomerCountBefore BIGINT;
DECLARE @CustomerCountAfter BIGINT;
DECLARE @FactCountBefore BIGINT;
DECLARE @FactCountAfter BIGINT;

SELECT @DateCountBefore = COUNT_BIG(*)
FROM mart.dim_date;

SELECT @ProductCountBefore = COUNT_BIG(*)
FROM mart.dim_product;

SELECT @CustomerCountBefore = COUNT_BIG(*)
FROM mart.dim_customer;

SELECT @FactCountBefore = COUNT_BIG(*)
FROM mart.fact_sales;

BEGIN TRY

    EXEC mart.usp_load_sales_mart;

    SELECT @DateCountAfter = COUNT_BIG(*)
    FROM mart.dim_date;

    SELECT @ProductCountAfter = COUNT_BIG(*)
    FROM mart.dim_product;

    SELECT @CustomerCountAfter = COUNT_BIG(*)
    FROM mart.dim_customer;

    SELECT @FactCountAfter = COUNT_BIG(*)
    FROM mart.fact_sales;

    INSERT INTO #DQResults
        (check_name, expected, actual, pass_fail)
    VALUES
    (
        'Stored procedure rerun row counts',
        'All dimension and fact counts unchanged',
        CONCAT(
            'Date: ', @DateCountBefore, ' -> ', @DateCountAfter,
            '; Product: ', @ProductCountBefore, ' -> ', @ProductCountAfter,
            '; Customer: ', @CustomerCountBefore, ' -> ', @CustomerCountAfter,
            '; Fact: ', @FactCountBefore, ' -> ', @FactCountAfter
        ),
        CASE
            WHEN @DateCountBefore = @DateCountAfter
             AND @ProductCountBefore = @ProductCountAfter
             AND @CustomerCountBefore = @CustomerCountAfter
             AND @FactCountBefore = @FactCountAfter
            THEN 'PASS'
            ELSE 'FAIL'
        END
    );

END TRY
BEGIN CATCH

    INSERT INTO #DQResults
        (check_name, expected, actual, pass_fail)
    VALUES
    (
        'Stored procedure rerun row counts',
        'Procedure executes successfully',
        CONCAT('SQL Error ', ERROR_NUMBER(), ': ', ERROR_MESSAGE()),
        'FAIL'
    );

END CATCH;

-------------------------------------------------------------
-- STEP 9: Display the complete results table
-------------------------------------------------------------

SELECT
    check_name,
    expected,
    actual,
    pass_fail
FROM #DQResults
ORDER BY check_name;

-------------------------------------------------------------
-- END OF DAY 4 DATA QUALITY CHECKS
-------------------------------------------------------------




USE AdventureWorksLT2022;
GO

-- Compare the two revenue totals in the source tables.
SELECT
    (SELECT SUM(SubTotal)
     FROM SalesLT.SalesOrderHeader) AS Header_SubTotal,

    (SELECT SUM(LineTotal)
     FROM SalesLT.SalesOrderDetail) AS Detail_LineTotal,

    (SELECT SUM(SubTotal)
     FROM SalesLT.SalesOrderHeader)
    -
    (SELECT SUM(LineTotal)
     FROM SalesLT.SalesOrderDetail) AS Difference;
