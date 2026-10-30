/*
===============================================================================
DAY 3 — SALES DATA MART
FILE 01: CREATE MART TABLES AND LOAD THE DATE DIMENSION
DATABASE: AdventureWorksLT2022

PURPOSE
-------
This script has two parts:
  PART 1: Create the mart schema and the five tables needed for the data mart.
  PART 2: Load the date dimension (mart.dim_date) using the source order dates.

IMPORTANT
---------
- Comments begin with -- or are written between /* and */.
- Comments explain the code; SQL Server does not execute them.
- IF OBJECT_ID / IF SCHEMA_ID checks prevent errors if these objects already exist.
- Run this script in SSMS while connected to the AdventureWorksLT2022 database.
===============================================================================
*/


/*=============================================================================
PART 0 — SELECT THE DATABASE
=============================================================================*/

-- Tell SQL Server which database this script should use.
USE AdventureWorksLT2022;
GO

-- Check the database currently selected.
-- EXPECTED OUTPUT: AdventureWorksLT2022
SELECT DB_NAME() AS current_database;
GO


/*=============================================================================
PART 1 — CREATE THE MART SCHEMA AND TABLES
=============================================================================*/

-- STEP 1: CREATE THE MART SCHEMA
-- A schema is a container that groups related database objects.
-- We put our reporting tables inside the schema named "mart".
-- If the schema already exists, skip creation so the script can be rerun.
IF SCHEMA_ID('mart') IS NULL
BEGIN
    EXEC('CREATE SCHEMA mart');
END;
GO


-- STEP 2: CREATE THE DATE DIMENSION
-- Purpose: Store calendar details used to group sales by date, month,
-- quarter, or year.
-- One row represents one calendar date.
-- date_key uses YYYYMMDD format, for example 20080601.
IF OBJECT_ID('mart.dim_date', 'U') IS NULL
BEGIN
    CREATE TABLE mart.dim_date
    (
        date_key INT NOT NULL PRIMARY KEY, -- Unique numeric key for the date
        [date] DATE NOT NULL UNIQUE,        -- Actual calendar date; no duplicates
        [month] TINYINT NOT NULL,           -- Month number: 1 to 12
        [quarter] TINYINT NOT NULL,         -- Quarter number: 1 to 4
        [year] SMALLINT NOT NULL            -- Calendar year, e.g. 2008
    );
END;
GO


-- STEP 3: CREATE THE PRODUCT DIMENSION
-- Purpose: Store descriptive information about each product.
-- product_key is a warehouse-generated key used by the mart.
-- product_id is the original product ID from SalesLT.Product.
IF OBJECT_ID('mart.dim_product', 'U') IS NULL
BEGIN
    CREATE TABLE mart.dim_product
    (
        product_key INT IDENTITY(1,1) PRIMARY KEY, -- Generated mart key
        product_id INT NOT NULL UNIQUE,            -- Source product ID; one row per product
        product_name NVARCHAR(50) NOT NULL,        -- Product name
        subcategory_id INT NULL,                   -- Subcategory ID, if available
        subcategory_name NVARCHAR(50) NULL,        -- Subcategory name, if available
        category_id INT NULL,                      -- Category ID, if available
        category_name NVARCHAR(50) NULL            -- Category name, if available
    );
END;
GO


-- STEP 4: CREATE THE CUSTOMER DIMENSION
-- Purpose: Store customer details and keep historical versions when a
-- customer's city or country changes. This approach is called SCD Type 2.
IF OBJECT_ID('mart.dim_customer', 'U') IS NULL
BEGIN
    CREATE TABLE mart.dim_customer
    (
        customer_key INT IDENTITY(1,1) PRIMARY KEY, -- Unique key for each version
        customer_id INT NOT NULL,                  -- Original ID from SalesLT.Customer
        customer_name NVARCHAR(200) NOT NULL,      -- Customer's full name
        city NVARCHAR(30) NULL,                    -- Customer city
        country NVARCHAR(50) NULL,                 -- Customer country
        valid_from DATE NOT NULL,                  -- First date this version is valid
        valid_to DATE NOT NULL,                    -- Last date this version is valid
        is_current BIT NOT NULL                    -- 1 = current; 0 = historical
            CONSTRAINT DF_dim_customer_is_current DEFAULT (1)
    );

    -- A customer can have several historical versions, but only one current row.
    -- This filtered unique index enforces that rule.
    CREATE UNIQUE INDEX UX_dim_customer_current
    ON mart.dim_customer(customer_id)
    WHERE is_current = 1;
END;

-- STEP 5: CREATE THE SALES FACT TABLE
-- Purpose: Store measurable sales data.
-- One row represents one sales order line (one product line within an order).
-- Foreign keys ensure each line points to an existing date, customer version,
-- and product in the dimension tables.
IF OBJECT_ID('mart.fact_sales', 'U') IS NULL
BEGIN
    CREATE TABLE mart.fact_sales
    (
        sales_order_detail_id INT NOT NULL PRIMARY KEY, -- Unique source order-line ID
        sales_order_id INT NOT NULL,                    -- Sales order ID
        date_key INT NOT NULL,                          -- Links to dim_date
        customer_key INT NOT NULL,                      -- Links to a customer version
        product_key INT NOT NULL,                       -- Links to dim_product
        quantity SMALLINT NOT NULL,                     -- Quantity sold
        unit_price DECIMAL(19,4) NOT NULL,              -- Price per unit
        discount_percent DECIMAL(19,4) NOT NULL,        -- Source discount value
        revenue DECIMAL(19,4) NOT NULL,                 -- Sales line total

        -- Link each fact row to the date dimension.
        CONSTRAINT FK_fact_sales_date
            FOREIGN KEY (date_key)
            REFERENCES mart.dim_date(date_key),

        -- Link each fact row to the correct customer version.
        CONSTRAINT FK_fact_sales_customer
            FOREIGN KEY (customer_key)
            REFERENCES mart.dim_customer(customer_key),

        -- Link each fact row to the product dimension.
        CONSTRAINT FK_fact_sales_product
            FOREIGN KEY (product_key)
            REFERENCES mart.dim_product(product_key)
    );
END;
GO


-- STEP 6: CREATE THE LOAD LOG TABLE
-- Purpose: Record each data-mart load attempt.
-- The log helps us see when a run started/ended and whether it succeeded.
IF OBJECT_ID('mart.load_log', 'U') IS NULL
BEGIN
    CREATE TABLE mart.load_log
    (
        log_id INT IDENTITY(1,1) PRIMARY KEY, -- Unique ID for each run
        start_time DATETIME2 NOT NULL,        -- Time the run started
        end_time DATETIME2 NULL,             -- Time the run ended; NULL while running
        rows_loaded INT NULL,                -- Count recorded by the loading process
        status VARCHAR(20) NOT NULL,         -- Example: Running, Success, Failed
        error_message NVARCHAR(4000) NULL    -- Error details, if a run fails
    );
END;
GO


/*=============================================================================
PART 2 — LOAD THE DATE DIMENSION (mart.dim_date)
=============================================================================*/

-- STEP 1: FIND THE FIRST AND LAST ORDER DATES IN THE SOURCE DATA.
-- SalesLT.SalesOrderHeader contains the order header and its OrderDate.
-- MIN finds the earliest date; MAX finds the latest date.
-- CAST(... AS DATE) removes the time portion, if one is present.
DECLARE @StartDate DATE;
DECLARE @EndDate DATE;

SELECT
    @StartDate = MIN(CAST(OrderDate AS DATE)),
    @EndDate = MAX(CAST(OrderDate AS DATE))
FROM SalesLT.SalesOrderHeader;


-- STEP 2: GENERATE EVERY DATE BETWEEN THE FIRST AND LAST ORDER DATES.
-- A recursive CTE (CalendarDates) starts with @StartDate, then adds one day
-- at a time until it reaches @EndDate.
-- If the source has only one distinct order date, this generates one date.
;WITH CalendarDates AS
(
    -- The first date in the calendar range.
    SELECT @StartDate AS CalendarDate
    WHERE @StartDate IS NOT NULL

    UNION ALL

    -- Add one day to the previous date, repeating until @EndDate is reached.
    SELECT DATEADD(DAY, 1, CalendarDate)
    FROM CalendarDates
    WHERE CalendarDate < @EndDate
)

-- STEP 3: INSERT OR UPDATE DATES USING MERGE.
-- Target = the destination table, mart.dim_date.
-- Source = the generated calendar dates and their month/quarter/year values.
-- WHEN MATCHED updates a date already in the table.
-- WHEN NOT MATCHED inserts a date that is not in the table.
MERGE mart.dim_date AS Target
USING
(
    SELECT
        -- Convert the date to YYYYMMDD and then to an integer.
        -- Example: 2008-06-01 becomes 20080601.
        CONVERT(INT, CONVERT(CHAR(8), CalendarDate, 112)) AS date_key,
        CalendarDate AS [date],
        MONTH(CalendarDate) AS [month],                   -- Month number 1–12
        DATEPART(QUARTER, CalendarDate) AS [quarter],     -- Quarter number 1–4
        YEAR(CalendarDate) AS [year]                     -- Calendar year
    FROM CalendarDates
) AS Source
ON Target.date_key = Source.date_key

WHEN MATCHED THEN
    UPDATE SET
        Target.[date] = Source.[date],
        Target.[month] = Source.[month],
        Target.[quarter] = Source.[quarter],
        Target.[year] = Source.[year]

WHEN NOT MATCHED BY TARGET THEN
    INSERT (date_key, [date], [month], [quarter], [year])
    VALUES (
        Source.date_key,
        Source.[date],
        Source.[month],
        Source.[quarter],
        Source.[year]
    )

-- Allow the recursive CTE to generate more than 100 dates if needed.
OPTION (MAXRECURSION 0);
GO


-- STEP 4: VERIFY THE DATE DIMENSION.
-- total_dates = number of date rows currently in mart.dim_date.
-- first_date = earliest loaded date.
-- last_date = latest loaded date.
SELECT
    COUNT(*) AS total_dates,
    MIN([date]) AS first_date,
    MAX([date]) AS last_date
FROM mart.dim_date;
GO

/*
WHAT TO EXPECT
--------------
The earlier profiling of this sample database showed that the earliest and
latest SalesLT.SalesOrderHeader OrderDate are both 2008-06-01.
Therefore this date-loading query is expected to load one date row:
  total_dates = 1
  first_date  = 2008-06-01
  last_date   = 2008-06-01

This result follows the source data currently available. It does not mean that
the date-dimension code is designed to load only one date; it generates the
whole range when the source contains a wider range.
*/



/*
========================================================
PART 3 — LOAD THE PRODUCT DIMENSION
========================================================

Purpose:
1. Read products from the SalesLT tables.
2. Get the product subcategory and category.
3. Update existing products in mart.dim_product.
4. Insert products that are missing.
5. Verify the final product count.

Important:
This code uses the actual columns in your existing
mart.dim_product table.
*/

USE AdventureWorksLT2022;
GO

-- Step 1: Prepare product information from the source tables.
;WITH ProductSource AS
(
    SELECT
        Product.ProductID,
        Product.Name AS ProductName,
        Product.ProductCategoryID AS SubcategoryID,
        Subcategory.Name AS SubcategoryName,
        Category.ProductCategoryID AS CategoryID,
        Category.Name AS CategoryName
    FROM SalesLT.Product AS Product

    -- Get the subcategory assigned to each product.
    LEFT JOIN SalesLT.ProductCategory AS Subcategory
        ON Product.ProductCategoryID = Subcategory.ProductCategoryID

    -- Get the parent category of that subcategory.
    LEFT JOIN SalesLT.ProductCategory AS Category
        ON Subcategory.ParentProductCategoryID =
           Category.ProductCategoryID
)

-- Step 2: Match source products with the target dimension.
MERGE mart.dim_product AS Target
USING ProductSource AS Source
    ON Target.product_id = Source.ProductID

-- Step 3: Update products that already exist.
WHEN MATCHED THEN
    UPDATE SET
        Target.product_name = Source.ProductName,
        Target.subcategory_id = Source.SubcategoryID,
        Target.subcategory_name = Source.SubcategoryName,
        Target.category_id = Source.CategoryID,
        Target.category_name = Source.CategoryName

-- Step 4: Insert products that do not exist yet.
WHEN NOT MATCHED BY TARGET THEN
    INSERT
    (
        product_id,
        product_name,
        subcategory_id,
        subcategory_name,
        category_id,
        category_name
    )
    VALUES
    (
        Source.ProductID,
        Source.ProductName,
        Source.SubcategoryID,
        Source.SubcategoryName,
        Source.CategoryID,
        Source.CategoryName
    );

GO

-- Step 5: Verify the loaded product records.
SELECT
    COUNT(*) AS total_products,
    COUNT(DISTINCT product_id) AS distinct_products
FROM mart.dim_product;

-- Step 6: View the first 10 products.
SELECT TOP 10 *
FROM mart.dim_product
ORDER BY product_id;
GO




/*
========================================================
PART 4 — LOAD CUSTOMER DIMENSION (SCD TYPE 2)
========================================================

PART 1: Expire old customer records when details change.
PART 2: Insert new customers and new current versions.
PART 3: Validate the customer dimension.

SCD Type 2 preserves historical customer information.
*/

USE AdventureWorksLT2022;
GO

-- STEP 1: Prepare one source row for each customer.
-- Prefer the Main Office address when available.

IF OBJECT_ID('tempdb..#CustomerSource') IS NOT NULL
    DROP TABLE #CustomerSource;

SELECT
    Customer.CustomerID AS customer_id,
    CONCAT(
        Customer.FirstName,
        ' ',
        Customer.LastName
    ) AS customer_name,
    SelectedAddress.City AS city,
    SelectedAddress.CountryRegion AS country
INTO #CustomerSource
FROM SalesLT.Customer AS Customer
OUTER APPLY
(
    SELECT TOP 1
        Address.City,
        Address.CountryRegion,
        CustomerAddress.AddressType,
        CustomerAddress.AddressID
    FROM SalesLT.CustomerAddress AS CustomerAddress
    INNER JOIN SalesLT.Address AS Address
        ON CustomerAddress.AddressID = Address.AddressID
    WHERE CustomerAddress.CustomerID = Customer.CustomerID
    ORDER BY
        CASE
            WHEN CustomerAddress.AddressType = 'Main Office'
                THEN 1
            ELSE 2
        END,
        CustomerAddress.AddressID
) AS SelectedAddress;


-- ======================================================
-- PART 1: EXPIRE OLD CURRENT RECORDS
-- ======================================================
-- If the customer's name, city, or country changes,
-- mark the previous record as no longer current.

UPDATE Target
SET
    Target.valid_to = DATEADD(
        DAY, -1, CAST(GETDATE() AS DATE)
    ),
    Target.is_current = 0
FROM mart.dim_customer AS Target
INNER JOIN #CustomerSource AS Source
    ON Target.customer_id = Source.customer_id
WHERE Target.is_current = 1
  AND
  (
      ISNULL(Target.customer_name, '') <>
          ISNULL(Source.customer_name, '')
      OR ISNULL(Target.city, '') <>
          ISNULL(Source.city, '')
      OR ISNULL(Target.country, '') <>
          ISNULL(Source.country, '')
  );


-- ======================================================
-- PART 2: INSERT NEW CUSTOMERS AND NEW VERSIONS
-- ======================================================
-- Insert a row when the customer does not have a current
-- record. This includes customers whose old record was
-- expired in Part 1.

INSERT INTO mart.dim_customer
(
    customer_id,
    customer_name,
    city,
    country,
    valid_from,
    valid_to,
    is_current
)
SELECT
    Source.customer_id,
    Source.customer_name,
    Source.city,
    Source.country,
    CAST(GETDATE() AS DATE),
    CAST('9999-12-31' AS DATE),
    1
FROM #CustomerSource AS Source
WHERE NOT EXISTS
(
    SELECT 1
    FROM mart.dim_customer AS Target
    WHERE Target.customer_id = Source.customer_id
      AND Target.is_current = 1
);


-- STEP 3: Remove the temporary source table.
DROP TABLE #CustomerSource;
GO


-- ======================================================
-- PART 3: VALIDATE THE CUSTOMER DIMENSION
-- ======================================================

-- Check total versions, unique customers, and current rows.
SELECT
    COUNT(*) AS total_versions,
    COUNT(DISTINCT customer_id) AS distinct_customers,
    SUM(
        CASE
            WHEN is_current = 1 THEN 1
            ELSE 0
        END
    ) AS current_customers
FROM mart.dim_customer;
GO

-- Check whether any customer has more than one current row.
-- Expected result: zero rows.

SELECT
    customer_id,
    COUNT(*) AS current_record_count
FROM mart.dim_customer
WHERE is_current = 1
GROUP BY customer_id
HAVING COUNT(*) > 1;
GO



USE AdventureWorksLT2022;
GO

-- Check the columns in the sales fact table.
SELECT
    COLUMN_NAME,
    DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'mart'
  AND TABLE_NAME = 'fact_sales'
ORDER BY ORDINAL_POSITION;
GO




/*
========================================================
PART 5 — LOAD THE FACT SALES TABLE
========================================================

Purpose:
1. Read sales order details from SalesLT.
2. Find the matching date, customer, and product keys.
3. Calculate revenue after discount.
4. Insert new sales detail records.
5. Avoid inserting duplicate sales detail IDs.
6. Validate the loaded sales data.

The fact table stores measurable sales information.
*/

USE AdventureWorksLT2022;
GO

-- STEP 1: Prepare sales details with dimension keys.
-- INNER JOIN ensures that each sales record has a matching
-- date, customer, and product dimension record.

;WITH SalesSource AS
(
    SELECT
        SalesOrderDetail.SalesOrderDetailID,
        SalesOrderDetail.SalesOrderID,
        CONVERT(
            INT,
            CONVERT(CHAR(8), SalesOrderHeader.OrderDate, 112)
        ) AS date_key,
        CustomerDimension.customer_key,
        ProductDimension.product_key,
        SalesOrderDetail.OrderQty AS quantity,
        SalesOrderDetail.UnitPrice AS unit_price,
        SalesOrderDetail.UnitPriceDiscount AS discount_percent,

        -- Revenue = quantity x unit price after discount.
        CAST(
            SalesOrderDetail.OrderQty
            * SalesOrderDetail.UnitPrice
            * (1 - SalesOrderDetail.UnitPriceDiscount)
            AS DECIMAL(18, 2)
        ) AS revenue

    FROM SalesLT.SalesOrderDetail AS SalesOrderDetail

    INNER JOIN SalesLT.SalesOrderHeader AS SalesOrderHeader
        ON SalesOrderDetail.SalesOrderID =
           SalesOrderHeader.SalesOrderID

    INNER JOIN mart.dim_date AS DateDimension
        ON DateDimension.date_key =
           CONVERT(
               INT,
               CONVERT(CHAR(8), SalesOrderHeader.OrderDate, 112)
           )

    INNER JOIN mart.dim_customer AS CustomerDimension
        ON CustomerDimension.customer_id =
           SalesOrderHeader.CustomerID
       AND CustomerDimension.is_current = 1

    INNER JOIN mart.dim_product AS ProductDimension
        ON ProductDimension.product_id =
           SalesOrderDetail.ProductID
)

-- STEP 2: Insert sales details that are not already in the fact table.
INSERT INTO mart.fact_sales
(
    sales_order_detail_id,
    sales_order_id,
    date_key,
    customer_key,
    product_key,
    quantity,
    unit_price,
    discount_percent,
    revenue
)
SELECT
    Source.SalesOrderDetailID,
    Source.SalesOrderID,
    Source.date_key,
    Source.customer_key,
    Source.product_key,
    Source.quantity,
    Source.unit_price,
    Source.discount_percent,
    Source.revenue
FROM SalesSource AS Source
WHERE NOT EXISTS
(
    SELECT 1
    FROM mart.fact_sales AS Target
    WHERE Target.sales_order_detail_id =
          Source.SalesOrderDetailID
);
GO

-- STEP 3: Validate the fact table.
-- Check the total rows, unique sales detail IDs, and revenue.

SELECT
    COUNT(*) AS total_fact_rows,
    COUNT(DISTINCT sales_order_detail_id) AS distinct_sales_details,
    SUM(revenue) AS total_revenue
FROM mart.fact_sales;
GO

-- STEP 4: Check for missing dimension keys.
-- Expected result: zero rows.

SELECT *
FROM mart.fact_sales
WHERE date_key IS NULL
   OR customer_key IS NULL
   OR product_key IS NULL;
GO


/*
========================================================
PART 6 — CREATE THE SALES MART LOAD PROCEDURE
========================================================

Purpose:
1. Automate the sales mart loading process.
2. Track the start and end times.
3. Record the number of affected rows.
4. Log successful and failed executions.
5. Roll back data changes if a load step fails.
*/

USE AdventureWorksLT2022;
GO

CREATE OR ALTER PROCEDURE mart.usp_load_sales_mart
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Variables used to track this procedure run.
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    DECLARE @RowsLoaded INT = 0;
    DECLARE @ErrorMessage NVARCHAR(MAX);

    BEGIN TRY

        -- Start a transaction so the data load is atomic.
        BEGIN TRANSACTION;

        /*
        Step 1:
        Load missing sales details into the fact table.

        This step uses the dimensions already loaded in
        Parts 2, 3, and 4.
        */

        ;WITH SalesSource AS
        (
            SELECT
                SalesOrderDetail.SalesOrderDetailID,
                SalesOrderDetail.SalesOrderID,
                CONVERT(
                    INT,
                    CONVERT(CHAR(8), SalesOrderHeader.OrderDate, 112)
                ) AS date_key,
                CustomerDimension.customer_key,
                ProductDimension.product_key,
                SalesOrderDetail.OrderQty AS quantity,
                SalesOrderDetail.UnitPrice AS unit_price,
                SalesOrderDetail.UnitPriceDiscount AS discount_percent,
                CAST(
                    SalesOrderDetail.OrderQty
                    * SalesOrderDetail.UnitPrice
                    * (1 - SalesOrderDetail.UnitPriceDiscount)
                    AS DECIMAL(18, 2)
                ) AS revenue
            FROM SalesLT.SalesOrderDetail AS SalesOrderDetail

            INNER JOIN SalesLT.SalesOrderHeader AS SalesOrderHeader
                ON SalesOrderDetail.SalesOrderID =
                   SalesOrderHeader.SalesOrderID

            INNER JOIN mart.dim_date AS DateDimension
                ON DateDimension.date_key =
                   CONVERT(
                       INT,
                       CONVERT(CHAR(8), SalesOrderHeader.OrderDate, 112)
                   )

            INNER JOIN mart.dim_customer AS CustomerDimension
                ON CustomerDimension.customer_id =
                   SalesOrderHeader.CustomerID
               AND CustomerDimension.is_current = 1

            INNER JOIN mart.dim_product AS ProductDimension
                ON ProductDimension.product_id =
                   SalesOrderDetail.ProductID
        )
        INSERT INTO mart.fact_sales
        (
            sales_order_detail_id,
            sales_order_id,
            date_key,
            customer_key,
            product_key,
            quantity,
            unit_price,
            discount_percent,
            revenue
        )
        SELECT
            Source.SalesOrderDetailID,
            Source.SalesOrderID,
            Source.date_key,
            Source.customer_key,
            Source.product_key,
            Source.quantity,
            Source.unit_price,
            Source.discount_percent,
            Source.revenue
        FROM SalesSource AS Source
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM mart.fact_sales AS Target
            WHERE Target.sales_order_detail_id =
                  Source.SalesOrderDetailID
        );

        -- Save the number of fact rows inserted.
        SET @RowsLoaded = @@ROWCOUNT;

        -- Commit changes when all steps succeed.
        COMMIT TRANSACTION;

        -- Step 2: Log the successful run.
        INSERT INTO mart.load_log
        (
            start_time,
            end_time,
            rows_loaded,
            status,
            error_message
        )
        VALUES
        (
            @StartTime,
            SYSDATETIME(),
            @RowsLoaded,
            'Success',
            NULL
        );

    END TRY
    BEGIN CATCH

        -- Roll back uncommitted data changes after an error.
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        -- Save the error details for troubleshooting.
        SET @ErrorMessage = ERROR_MESSAGE();

        -- Log the failed run.
        INSERT INTO mart.load_log
        (
            start_time,
            end_time,
            rows_loaded,
            status,
            error_message
        )
        VALUES
        (
            @StartTime,
            SYSDATETIME(),
            @RowsLoaded,
            'Failed',
            @ErrorMessage
        );

        -- Return the original error to SSMS.
        THROW;

    END CATCH;
END;
GO

-- Verify that the stored procedure exists.
SELECT
    SCHEMA_NAME(schema_id) AS schema_name,
    name AS procedure_name
FROM sys.procedures
WHERE schema_id = SCHEMA_ID('mart')
  AND name = 'usp_load_sales_mart';
GO




-- Run the sales mart loading procedure.
EXEC mart.usp_load_sales_mart;
GO

-- Check the latest load log entries.
SELECT TOP 10
    log_id,
    start_time,
    end_time,
    rows_loaded,
    status,
    error_message
FROM mart.load_log
ORDER BY log_id DESC;
GO


--VALIDATION


USE AdventureWorksLT2022;
GO

-- Compare revenue calculated from source sales details
-- with the revenue stored in the fact table.

SELECT
    'Source Sales Details' AS data_source,
    COUNT(*) AS total_rows,
    SUM(LineTotal) AS total_revenue
FROM SalesLT.SalesOrderDetail

UNION ALL

SELECT
    'Mart Fact Sales' AS data_source,
    COUNT(*) AS total_rows,
    SUM(revenue) AS total_revenue
FROM mart.fact_sales;
GO

