
USE [DBA] 
IF NOT EXISTS(SELECT schema_id FROM sys.schemas WHERE name='maintenance')
begin

	DECLARE @sql_string AS NVARCHAR(MAX) = 'CREATE SCHEMA [maintenance] AUTHORIZATION [dbo]'
	EXEC sp_executesql @sql_string

end
