

-- 1 .List every table in the SalesLT schema with its row count, using ONE query (hint: sys.tables + sys.partitions).

/*“First, I select the information about tables from the SQL Server system view sys.tables. 
Then, I join it with sys.partitions to get the row-count information. 
I match both sources using object_id. After that,
I filter the results to include only the SalesLT schema and select the appropriate index types to avoid counting rows more than once. 
Finally, I group the data by schema and table name, calculate the total row count, and sort the table names alphabetically.”*/

USE AdventureWorksLT2022;
GO

SELECT
    SCHEMA_NAME(t.schema_id) AS schema_name,
    t.name AS table_name,
    SUM(p.rows) AS row_count
FROM sys.tables AS t
INNER JOIN sys.partitions AS p
    ON t.object_id = p.object_id
WHERE SCHEMA_NAME(t.schema_id) = 'SalesLT'
  AND p.index_id IN (0, 1)
GROUP BY
    SCHEMA_NAME(t.schema_id),
    t.name
ORDER BY
    t.name;

  -- 2. Find the primary key and foreign keys of every table (INFORMATION_SCHEMA and sys.foreign_keys).
  /*“First, I select the AdventureWorksLT2022 database. Then, I retrieve schema names, table names, 
  column names, and constraint names from INFORMATION_SCHEMA.KEY_COLUMN_USAGE. 
  I use a subquery on INFORMATION_SCHEMA.TABLE_CONSTRAINTS to identify constraints of type Primary Key.
  I filter the results to the SalesLT schema, and finally, I sort them by table name and column position. 
  This helps me identify the Primary Key columns in each table.”*/

  USE AdventureWorksLT2022;
GO

SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    COLUMN_NAME,
    CONSTRAINT_NAME
FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = 'SalesLT'
  AND CONSTRAINT_NAME IN (
      SELECT CONSTRAINT_NAME
      FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
      WHERE TABLE_SCHEMA = 'SalesLT'
        AND CONSTRAINT_TYPE = 'PRIMARY KEY'
  )
ORDER BY TABLE_NAME, ORDINAL_POSITION;

-- B. Find all Foreign Keys (FKs)
/*“First, I access the AdventureWorksLT2022 database. Then, I retrieve Foreign Key information from the SQL Server system views. 
I join the Foreign Key details with the table and column information to identify both sides of each relationship. 
After that, I filter the results to include only the SalesLT schema. Finally, I display the Foreign Key name, the column containing it, 
and the referenced table and column, and sort the results by table name.”*/

USE AdventureWorksLT2022;
GO

SELECT
    SCHEMA_NAME(parent_table.schema_id) AS schema_name,
    parent_table.name AS table_name,
    parent_column.name AS column_name,
    foreign_key.name AS foreign_key_name,
    SCHEMA_NAME(referenced_table.schema_id) AS referenced_schema,
    referenced_table.name AS referenced_table,
    referenced_column.name AS referenced_column
FROM sys.foreign_keys AS foreign_key
INNER JOIN sys.foreign_key_columns AS foreign_key_column
    ON foreign_key.object_id = foreign_key_column.constraint_object_id
INNER JOIN sys.tables AS parent_table
    ON foreign_key_column.parent_object_id = parent_table.object_id
INNER JOIN sys.columns AS parent_column
    ON foreign_key_column.parent_object_id = parent_column.object_id
   AND foreign_key_column.parent_column_id = parent_column.column_id
INNER JOIN sys.tables AS referenced_table
    ON foreign_key_column.referenced_object_id = referenced_table.object_id
INNER JOIN sys.columns AS referenced_column
    ON foreign_key_column.referenced_object_id = referenced_column.object_id
   AND foreign_key_column.referenced_column_id = referenced_column.column_id
WHERE SCHEMA_NAME(parent_table.schema_id) = 'SalesLT'
ORDER BY parent_table.name, foreign_key.name;

--Task 4A — Check NULL counts and distinct counts
--Step 1: Check Customer data
/*“This query performs a data-quality check on the Customer table. First, it counts the total customer records.
Then, it counts the non-NULL and NULL values in the FirstName, LastName, and EmailAddress columns. 
Finally, it counts the distinct email addresses.
This helps us understand whether customer information is missing and how many unique email addresses are available.”*/

USE AdventureWorksLT2022;
GO

SELECT
    COUNT(*) AS total_customers,
    COUNT(FirstName) AS non_null_first_names,
    COUNT(*) - COUNT(FirstName) AS null_first_names,
    COUNT(LastName) AS non_null_last_names,
    COUNT(*) - COUNT(LastName) AS null_last_names,
    COUNT(EmailAddress) AS non_null_emails,
    COUNT(*) - COUNT(EmailAddress) AS null_emails,
    COUNT(DISTINCT EmailAddress) AS distinct_emails
FROM SalesLT.Customer;


--Step 2: Check Product data
/*“In Step 2, I performed a data-quality check on the Product table.
I counted the total number of products and checked for missing values in the Name, 
ProductNumber, and ListPrice columns. I also counted the distinct product numbers to check how many unique product identifiers are available. 
This helps us identify missing product information and potential duplicate product numbers.”*/

SELECT
    COUNT(*) AS total_products,
    COUNT(Name) AS non_null_names,
    COUNT(*) - COUNT(Name) AS null_names,
    COUNT(ProductNumber) AS non_null_product_numbers,
    COUNT(*) - COUNT(ProductNumber) AS null_product_numbers,
    COUNT(ListPrice) AS non_null_list_prices,
    COUNT(*) - COUNT(ListPrice) AS null_list_prices,
    COUNT(DISTINCT ProductNumber) AS distinct_product_numbers
FROM SalesLT.Product;


--Task 4B — Check minimum and maximum order dates

SELECT
    MIN(OrderDate) AS earliest_order_date,
    MAX(OrderDate) AS latest_order_date,
    COUNT(*) AS total_orders,
    COUNT(OrderDate) AS non_null_order_dates,
    COUNT(*) - COUNT(OrderDate) AS null_order_dates
FROM SalesLT.SalesOrderHeader;


-- Task 4C — Check zero or negative prices and quantities
/*“I performed a data-quality check on the SalesOrderDetail table. First, 
I counted the total order-detail records. Then, I checked UnitPrice and OrderQty for missing, zero and negative values using CASE WHEN conditions and SUM. 
This helps identify potentially invalid pricing and quantity records before using the data for analysis.”*/

SELECT
    COUNT(*) AS total_order_details,

    SUM(CASE WHEN UnitPrice IS NULL THEN 1 ELSE 0 END)
        AS null_unit_prices,
    SUM(CASE WHEN UnitPrice = 0 THEN 1 ELSE 0 END)
        AS zero_unit_prices,
    SUM(CASE WHEN UnitPrice < 0 THEN 1 ELSE 0 END)
        AS negative_unit_prices,

    SUM(CASE WHEN OrderQty IS NULL THEN 1 ELSE 0 END)
        AS null_quantities,
    SUM(CASE WHEN OrderQty = 0 THEN 1 ELSE 0 END)
        AS zero_quantities,
    SUM(CASE WHEN OrderQty < 0 THEN 1 ELSE 0 END)
        AS negative_quantities
FROM SalesLT.SalesOrderDetail;

-- Task 4D — Check distinct counts for important columns

SELECT
    COUNT(DISTINCT CustomerID) AS distinct_customers
FROM SalesLT.SalesOrderHeader;

SELECT
    COUNT(DISTINCT ProductID) AS distinct_products
FROM SalesLT.SalesOrderDetail;

SELECT
    COUNT(DISTINCT SalesOrderID) AS distinct_orders
FROM SalesLT.SalesOrderDetail;

--- PRACTICEE


USE AdventureWorksLT2022;

USE AdventureWorksLT2022;

SELECT TABLE_SCHEMA, TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;




USE AdventureWorksLT2022;

SELECT TOP 10 * FROM SalesLT.Address;
SELECT TOP 5 * FROM SalesLT.Customer;
SELECT TOP 5 * FROM SalesLT.CustomerAddress;
SELECT TOP 5 * FROM SalesLT.Product;
SELECT TOP 5 * FROM SalesLT.ProductCategory;
SELECT TOP 5 * FROM SalesLT.ProductDescription;
SELECT TOP 5 * FROM SalesLT.ProductModel;
SELECT TOP 5 * FROM SalesLT.ProductModelProductDescription;
SELECT TOP 5 * FROM SalesLT.SalesOrderDetail;
SELECT TOP 5 * FROM SalesLT.SalesOrderHeader;



