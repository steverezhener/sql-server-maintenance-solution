USE [DBA] 
DECLARE @schema_name AS NVARCHAR(100) = 'bestpractices'
IF NOT EXISTS(SELECT schema_id FROM sys.schemas WHERE name=@schema_name)
begin

	DECLARE @sql_string AS NVARCHAR(MAX) = 'CREATE SCHEMA @schema_name AUTHORIZATION [dbo]'
    SET @sql_string = REPLACE(@sql_string, '@schema_name', QUOTENAME (@schema_name))

	EXEC sp_executesql @sql_string

end
