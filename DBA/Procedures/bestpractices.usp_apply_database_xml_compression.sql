USE [DBA]
GO
/****** Object:  StoredProcedure [bestpractices].[usp_collect_database_compression_estimate]    Script Date: 6/25/2024 3:25:07 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		Steve Rezhener
-- Create date: 04/01/2025
-- Description:	compress tables with xml data dype columns
-- EXEC DBA.bestpractices.usp_apply_database_xml_compression 
-- EXEC DBA.bestpractices.usp_apply_database_xml_compression @debug_only='Y'
-- =============================================
CREATE OR ALTER                 PROCEDURE [bestpractices].[usp_apply_database_xml_compression]
	@top_tables					INT					    = 5
	,@include_database_list				NVARCHAR(MAX)		= NULL	--overwrites configuration table value	(use commas with no spaces)
	,@exclude_database_list				NVARCHAR(MAX)		= NULL	--overwrites configuration table value	(use commas with no spaces)
	,@read_write_mode				VARCHAR(25)		= 'READ_WRITE'
	,@exclude_table					VARCHAR(100)		= NULL	
	,@recommended_database_option_name		VARCHAR(50)		= 'XML_COMPRESSION'
	,@recommended_value				CHAR(2)			= 'ON'
	,@command_type					VARCHAR(50)		= 'ALTER TABLE (XML_COMPRESSION=ON)'
	,@log_to_table					CHAR(1)			= 'Y'
	,@debug_only					CHAR(1)			= 'N'
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @Version VARCHAR(10) = '1.02' 	-- added xml_compression=OFF filter

	DECLARE @database_name		SYSNAME
	DECLARE @sql_string			NVARCHAR(MAX)
	DECLARE @database_count		INT, @database_inc INT = 0
	DECLARE @is_read_only		CHAR(1) = IIF(@read_write_mode='READ_WRITE',0,1)
	DECLARE @configured_value	NVARCHAR(2000) 
	DECLARE @compression_type	VARCHAR(50)	
	DECLARE @product_edition	VARCHAR(50)	= CONVERT(VARCHAR(50),SERVERPROPERTY('Edition'))
	DECLARE @product_version	VARCHAR(50)	= CONVERT(VARCHAR(50),SERVERPROPERTY('ProductVersion'))
	DECLARE @id					INT
	DECLARE @size_with_current_compression_setting_kb INT , @size_with_requested_compression_setting_kb INT
	DECLARE @StartTime datetime2, @EndTime datetime2, @log_id int
	DECLARE @error_message VARCHAR(1000)

	IF LEFT(@product_version,2) < 16 	-- xml compression is only available from sql server 2022 and up
	BEGIN
		RAISERROR('%s feature is not supported in %s - exiting now',0,1,@recommended_database_option_name,@product_version) WITH NOWAIT
		RETURN
	END
	ELSE
	BEGIN
		RAISERROR('%s feature is supported in %s - moving on',0,1,@recommended_database_option_name,@product_version) WITH NOWAIT
	END

	--Settings
	BEGIN

		SET @configured_value = (SELECT SettingValue							FROM [DBA].[maintenance].[Configuration]		WHERE 1=1 AND [SettingName] = 'is_database_xml_compression_on_databaselist')
		--INSERT INTO [DBA].[maintenance].[Configuration] (SettingName, [SettingValue]) VALUES ('is_database_xml_compression_on_databaselist','')
		--UPDATE	[DBA].[maintenance].[Configuration]	SET		[SettingValue]='%,-DWConfiguration,-DWDiagnostics,-DWQueue' WHERE	[SettingName]='is_database_xml_compression_on_databaselist'

		DROP TABLE IF EXISTS #configuration_database_list;	
		CREATE TABLE #configuration_database_list ([database_name] NVARCHAR(250)) 

		INSERT INTO #configuration_database_list ([database_name])	SELECT REPLACE(Value,' ','') FROM STRING_SPLIT(@configured_value,',')
		
		IF ISNULL(@include_database_list,'')='' 
			SET @include_database_list = (SELECT STRING_AGG([database_name],',') FROM  #configuration_database_list WHERE LEFT([database_name],1)!='-')
	
		IF ISNULL(@exclude_database_list,'')='' 
			SET @exclude_database_list = (SELECT REPLACE(STRING_AGG([database_name],','),'-','') FROM #configuration_database_list WHERE LEFT([database_name],1)='-')

	END

	IF ISNULL(@include_database_list,'')=''
	BEGIN
		RAISERROR('@include_database_list is empty!',11,1) WITH NOWAIT
		RETURN
	END
	
	IF @debug_only='Y' RAISERROR('debug only, faking it!',0,1) WITH NOWAIT

	DROP TABLE IF EXISTS #database_work_list 
	CREATE TABLE #database_work_list (database_name NVARCHAR(100))
	
	DROP TABLE IF EXISTS #xml_compression_list
	CREATE TABLE #xml_compression_list ([database_name] NVARCHAR(50) NULL, [schema_name] VARCHAR(50), [table_Name] VARCHAR(50), [column_name] VARCHAR(50));
	
	DROP TABLE IF EXISTS #compression_estimate
	CREATE TABLE #compression_estimate (id INT IDENTITY(1,1),[database_name] nvarchar(50), [table_name] sysname, [schema_name] sysname, column_name sysname NULL, index_id int, partition_number int, size_with_current_compression_setting_kb bigint,
		size_with_requested_compression_setting_kb bigint, sample_size_with_current_compression_setting_kb bigint,	sample_size_with_requested_compression_setting_kb bigint);

	SET @sql_string = 'SELECT	name'
	SET @sql_string += ' FROM	sys.databases'
	SET @sql_string += ' WHERE	database_id > 4'
	SET @sql_string += ' AND is_read_only = ISNULL(@is_read_only,is_read_only)'
	SET @sql_string += ' AND state_desc = ''ONLINE'''
	SET @sql_string += ' AND user_access_desc = ''MULTI_USER'''
	
	IF CHARINDEX('%',@include_database_list)>0 
		SET @sql_string += ' AND [name] LIKE '''+@include_database_list+''''
	ELSE IF ISNULL(@include_database_list,'') != ''
		SET @sql_string += ' AND [name] IN (SELECT Value FROM STRING_SPLIT('''+@include_database_list+''','',''))'
	
	IF ISNULL(@exclude_database_list,'') != ''	SET @sql_string += ' AND name NOT IN (SELECT Value FROM STRING_SPLIT('''+@exclude_database_list+''','',''))'
   
	SET @sql_string += ' ORDER BY [name] ASC'

	SET @sql_string = REPLACE(@sql_string,'@is_read_only', @is_read_only)

	RAISERROR ('@sql_string = %s', 0, 1, @sql_string) WITH NOWAIT
	INSERT INTO #database_work_list (database_name) EXEC sp_executesql @sql_string

	--IF @debug_only='Y'	SELECT * FROM #database_work_list

	DECLARE database_cursor CURSOR LOCAL STATIC FORWARD_ONLY READ_ONLY FOR
	SELECT	database_name	
	FROM	#database_work_list
	
	OPEN database_cursor;
	FETCH NEXT FROM database_cursor INTO @database_name
	
	SET @database_count = @@CURSOR_ROWS

	WHILE @@FETCH_STATUS = 0
	BEGIN
		
		SET @database_inc +=1
		RAISERROR ('starting XML compression analysis on %s database (%d of %d total)...', 0, 1, @database_name, @database_inc, @database_count) WITH NOWAIT
		
		-- added to prevent dropped databases from compression collection
		IF NOT EXISTS(SELECT	name FROM	sys.databases WHERE name = @database_name) BREAK
		
		SET @sql_string = 'USE [@database_name]'
		SET @sql_string += ' SELECT'
		SET @sql_string += ' DB_NAME() AS [database_name], mas.name AS [schema_name], tabs.name as [table_name], cols.name as [column_name]'
        SET @sql_string += ' FROM	sys.tables as tabs'
		SET @sql_string += ' INNER join sys.schemas as mas on mas.schema_id = tabs.schema_id'
        SET @sql_string += ' INNER join sys.columns as cols on cols.object_id = tabs.object_id'
		SET @sql_string += ' INNER join sys.types AS typs ON typs.system_type_id = cols.system_type_id'
		SET @sql_string += ' INNER JOIN sys.partitions as pars ON pars.object_id = tabs.object_id AND pars.index_id=1'
		SET @sql_string += ' WHERE 1=1'

		IF ISNULL(@exclude_table,'')!='' 
		BEGIN
			SET @sql_string += ' AND o.name != ''@exclude_table'''
			SET @sql_string = REPLACE(@sql_string,'@exclude_table',@exclude_table) 
		END
		
		SET @sql_string += ' AND typs.name=''xml'''
		SET @sql_string += ' AND pars.xml_compression_desc=''OFF'''
		SET @sql_string += ' ORDER BY database_name ASC;'

		SET @sql_string = REPLACE(@sql_string,'@database_name',@database_name)
		SET @sql_string = REPLACE(@sql_string,'@top_tables',@top_tables)

		RAISERROR('@sql_string: %s',0,1,@sql_string) WITH NOWAIT
		INSERT INTO #xml_compression_list ([database_name],[schema_name],[table_name],[column_name]) EXEC sp_executesql @sql_string
		
		RAISERROR ('completed XML compression analysis on %s database (%d of %d total)!', 0, 1, @database_name, @database_inc, @database_count) WITH NOWAIT

		FETCH NEXT FROM database_cursor INTO @database_name

	END

	CLOSE database_cursor
	DEALLOCATE database_cursor;

	DECLARE @schema_name NVARCHAR(50), @table_name NVARCHAR(100), @column_name AS VARCHAR(100)
		
	DECLARE database_schema_table_column CURSOR LOCAL STATIC FORWARD_ONLY READ_ONLY FOR 
	SELECT	[database_name],[schema_name], [table_name], [column_name]
	FROM	#xml_compression_list
	
	OPEN database_schema_table_column
	FETCH NEXT FROM database_schema_table_column INTO @database_name,@schema_name,@table_name,@column_name

	WHILE @@FETCH_STATUS = 0
	BEGIN

		-- added to prevent dropped databases from compression collection
		IF NOT EXISTS(SELECT	name FROM	sys.databases WHERE name = @database_name) BREAK

		RAISERROR('collecting XML compression estimate on [%s].[%s].[%s].[%s] ...',0,1,@database_name,@schema_name,@table_name,@column_name) WITH NOWAIT
		SET @sql_string = 'USE [@database_name]' 
		SET @sql_string += ' IF EXISTS(SELECT tabs.object_id FROM sys.tables AS tabs INNER JOIN sys.schemas AS mas ON mas.schema_id = tabs.schema_id WHERE 1=1 AND tabs.name=''@table_name'' AND mas.name=''@schema_name1'')'
		SET @sql_string += ' BEGIN'
		SET @sql_string += ' EXEC sp_estimate_data_compression_savings @schema_name=''@schema_name1'',@object_name=''@table_name'',@index_id=1,@partition_number=NULL, @data_compression=NULL,@xml_compression=1'
		SET @sql_string += ' END'

		SET @sql_string = REPLACE(@sql_string, '@database_name',@database_name)
		SET @sql_string = REPLACE(@sql_string, '@schema_name1',@schema_name)
		SET @sql_string = REPLACE(@sql_string, '@table_name',@table_name)
			
		BEGIN TRY
				SET @id=NULL
				RAISERROR('@sql_string: %s',0,1,@sql_string) WITH NOWAIT
				INSERT INTO #compression_estimate ([table_name], [schema_name], index_id, partition_number, size_with_current_compression_setting_kb, size_with_requested_compression_setting_kb, sample_size_with_current_compression_setting_kb, sample_size_with_requested_compression_setting_kb)
				EXEC sp_executesql @sql_string
				SET @id= SCOPE_IDENTITY()

				UPDATE	#compression_estimate
				SET		[database_name]=@database_name, [column_name] = @column_name
				WHERE	ID=@id
		END TRY
		BEGIN CATCH
			SET @error_message = CONVERT(VARCHAR(1000),ERROR_MESSAGE())
			RAISERROR('?--> error: %s',0,1,@error_message) WITH NOWAIT
		END CATCH

		--SELECT * from #compression_estimate

		RAISERROR('collected XML compression estimate on [%s].[%s].[%s].[%s] !',0,1,@database_name,@schema_name,@table_name,@column_name) WITH NOWAIT

		SELECT	@database_name=[database_name], @size_with_current_compression_setting_kb = size_with_current_compression_setting_kb 
				, @size_with_requested_compression_setting_kb = size_with_requested_compression_setting_kb 
		FROM	#compression_estimate
		WHERE	ID=@id

		RAISERROR('@size_with_current_compression_setting_kb=%d vs. xml @compressed size_with_current_compression_setting_kb=%d',0,1,@size_with_current_compression_setting_kb,@size_with_requested_compression_setting_kb) WITH NOWAIT
		IF @size_with_current_compression_setting_kb > @size_with_requested_compression_setting_kb
		BEGIN

			RAISERROR('->applying XML_COMPRESSION = ON...',0,1) WITH NOWAIT
			SET @sql_string = 'USE [@database_name]'
			SET @sql_string += ' ALTER TABLE [@schema_name].[@table_name] REBUILD PARTITION = ALL WITH (@recommended_database_option_name = @recommended_value)'

			SET @sql_string = REPLACE(@sql_string, '@database_name',@database_name)
			SET @sql_string = REPLACE(@sql_string, '@schema_name',@schema_name)
			SET @sql_string = REPLACE(@sql_string, '@table_name',@table_name)
			SET @sql_string = REPLACE(@sql_string, '@recommended_database_option_name',@recommended_database_option_name)
			SET @sql_string = REPLACE(@sql_string, '@recommended_value',@recommended_value)

			IF @log_to_table = 'Y' AND @debug_only = 'N'
			BEGIN
				SET @StartTime = SYSDATETIME()
				INSERT INTO DBA.dbo.CommandLog (DatabaseName, SchemaName, ObjectName, ObjectType, IndexName, IndexType, StatisticsName, PartitionNumber, ExtendedInfo, CommandType, Command, StartTime)
				VALUES (@database_name, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, @command_type, @sql_string, @StartTime)
				SET @log_id = SCOPE_IDENTITY()
			END

			RAISERROR('@sql_string: %s',0,1,@sql_string) WITH NOWAIT
			IF @debug_only = 'N' EXEC sp_executesql @sql_string
			RAISERROR('->applied XML_COMPRESSION = ON!',0,1) WITH NOWAIT

			IF @log_to_table = 'Y' AND @debug_only = 'N'
			BEGIN
				SET @EndTime = SYSDATETIME()
				UPDATE	DBA.dbo.CommandLog		SET		EndTime = @EndTime	WHERE	ID = @log_id
			END

		END
			

		FETCH NEXT FROM database_schema_table_column INTO @database_name,@schema_name,@table_name,@column_name

	END

	CLOSE database_schema_table_column
	DEALLOCATE database_schema_table_column;

	IF @debug_only = 'N'
		SELECT * FROM #compression_estimate where size_with_current_compression_setting_kb > size_with_requested_compression_setting_kb
	ELSE
		SELECT * FROM #compression_estimate where 1=1 --order by 

END
