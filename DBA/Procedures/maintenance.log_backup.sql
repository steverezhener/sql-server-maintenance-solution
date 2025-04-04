USE [DBA]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:			Steve Rezhener
-- Create date: 	04/04/2025
-- Description:		Runs log backup using Ola Hallenger script
-- EXEC DBA.maintenance.log_backup 
-- EXEC DBA.maintenance.log_backup @specific_database_name='DBA'
-- EXEC DBA.maintenance.log_backup @debug_only='Y',@log_to_table='N'
CREATE OR ALTER           PROCEDURE [maintenance].[log_backup]
	@specific_database_name			NVARCHAR(50)	= NULL
	,@use_backup_configuration		CHAR(1)			= 'N'
	,@debug_only					CHAR(1)			= 'N'
	,@log_to_table					CHAR(1)			= 'Y'

AS
BEGIN

	SET NOCOUNT ON;

	DECLARE @Version VARCHAR(10) = '1.05' 	--- added compress Y/N condition

	DECLARE @description AS VARCHAR(50) = 'Regular Log Backup'
	DECLARE @NumberOfFiles AS TINYINT 
	DECLARE @BackupShare AS VARCHAR(500), @LocalBackup AS VARCHAR(500), @local_backup_files NVARCHAR(500)
 	DECLARE @MaxTransferSize INT, @Buffercount INT, @BlockSize INT
	DECLARE @DatabaseList NVARCHAR(MAX)
	DECLARE @CleanupTime INT = 31*24	-- 31 days x 24 hours = 744
	DECLARE @excludedatabaselist AS NVARCHAR(MAX)
	DECLARE @TotalRAMAvailable_in_KB AS INT 
	DECLARE @default_MaxTransferSize BIGINT = 65536*POWER(2,4) --1024MB
	DECLARE @OtherSystemDatabases AS NVARCHAR(MAX)
	DECLARE @EnableBackupMirroring	AS CHAR(1) 
	DECLARE @Edition VARCHAR(20) = (SELECT CONVERT(VARCHAR, SERVERPROPERTY('Edition')))
	DECLARE @Compress CHAR(1)

	--Settings
	BEGIN

		SET @TotalRAMAvailable_in_KB = (SELECT [total_physical_memory_kb] FROM [master].[sys].[dm_os_sys_memory])
		SET @NumberOfFiles = (SELECT case when cpu_count >=8 THEN 8 ELSE cpu_count END FROM master.sys.dm_os_sys_info)
		SET @CleanupTime = (SELECT	CAST([SettingValue] AS INT) FROM [Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'CleanupTimeHours')
		SET @BackupShare = (SELECT [mc].[SettingValue] FROM [Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'BackupPath')
		SET @LocalBackup = (SELECT [mc].[SettingValue] FROM [Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'MirrorDirectory')
		SET @EnableBackupMirroring = (SELECT [mc].[SettingValue] FROM [Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'BackupMirroring')
		SET @OtherSystemDatabases = (SELECT [SettingValue] from Maintenance.Configuration where 1=1 AND SettingName='OtherSystemDatabases')
		SET @excludedatabaselist = (SELECT [SettingValue] from [Maintenance].[Configuration] where 1=1 AND SettingName='LogBackupExcludeDatabaseList')

		--backup configurations
		SET @MaxTransferSize = (SELECT CAST([SettingValue] AS INT) FROM DBA.[Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'BackupMaxTransferSize')
		SET @Buffercount = (SELECT CAST([SettingValue] AS INT) FROM  DBA.[Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'BackupBuffercount')
		SET @BlockSize = (SELECT CAST([SettingValue] AS INT) FROM  DBA.[Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'BackupBlockSize') 

		IF CHARINDEX(@Edition,'Standard',1) >0 AND CHARINDEX(@Edition,'Developer',1) >0 AND CHARINDEX(@Edition,'Enterprise',1) >0
			SET @Compress='Y'
		ELSE
			SET @Compress='N'

		IF ISNULL(@MaxTransferSize,'')='' OR ISNULL(@Buffercount,'')='' OR ISNULL(@BlockSize,'')='' OR @BlockSize=4194304 --populate custom backup configuration for the first time
		BEGIN

			RAISERROR('recalculating backup optimization values...',0,1) WITH NOWAIT
			EXEC DBA.bestpractices.usp_find_server_optimal_backup_configs
			EXEC DBA.bestpractices.usp_optimize_server_database_backups
			RAISERROR('recalculated backup optimization values...',0,1) WITH NOWAIT

		END
		
	END

	IF ISNULL(@EnableBackupMirroring,'N')='Y'	SET @BackupShare = @LocalBackup

	SELECT	@excludedatabaselist = STRING_AGG([sq].[Value], ',')
	FROM
			(
				SELECT	[Value] = CONCAT('-',TRIM([ss].[value]))
				FROM	STRING_SPLIT(@excludedatabaselist, ',') AS [ss]
				WHERE	ISNULL([ss].[Value],'')!=''
			) AS [sq]


	SET @DatabaseList = 'USER_DATABASES'
	IF ISNULL(@excludedatabaselist,'')!='' 			SET @DatabaseList = CONCAT('USER_DATABASES,',@excludedatabaselist)
	IF ISNULL(@OtherSystemDatabases,'')!=''			SET @DatabaseList = @OtherSystemDatabases		
	IF ISNULL(@specific_database_name,'')!='' 		SET @DatabaseList = @specific_database_name
	
	RAISERROR('Starting EXECUTE [dbo].[DatabaseBackup] @Databases = ''%s'',@Directory = ''%s'',@BackupType = ''LOG'',@Verify = ''Y'',@CleanupTime = ''%d''
			,@CleanupMode = ''AFTER_BACKUP'',@Compress = ''Y'',@CopyOnly = ''N'',@ChangeBackupType = ''Y'',@BackupSoftware = NULL,@CheckSum = ''Y''
			,@Description =  ''%s'',@DatabaseOrder = ''DATABASE_SIZE_DESC'',@DatabasesInParallel = ''Y'',@LogToTable = ''%s''
			,@MaxTransferSize=''%d'', @Buffercount=''%d'', @BlockSize=''%d''...',0,1,@DatabaseList,@BackupShare,@CleanupTime,@description,@log_to_table,@MaxTransferSize,@Buffercount,@BlockSize) WITH NOWAIT

	IF @debug_only='N'
	BEGIN
	
		IF @use_backup_configuration='Y' 
		BEGIN

			EXECUTE [dbo].[DatabaseBackup] @Databases = @DatabaseList,@Directory = @BackupShare,@BackupType = 'LOG',@Verify = 'Y',@CleanupTime = @CleanupTime
				,@CleanupMode = 'AFTER_BACKUP',@Compress = @Compress,@CopyOnly = 'N',@ChangeBackupType = 'Y',@BackupSoftware = NULL,@CheckSum = 'Y'
				,@Description = @description,@DatabaseOrder = 'DATABASE_SIZE_DESC',@DatabasesInParallel = 'Y',@LogToTable = @log_to_table
				,@MaxTransferSize=@MaxTransferSize, @Buffercount=@Buffercount, @BlockSize=@BlockSize
		END
		ELSE
		BEGIN

			EXECUTE [dbo].[DatabaseBackup] @Databases = @DatabaseList,@Directory = @BackupShare,@BackupType = 'LOG',@Verify = 'Y',@CleanupTime = @CleanupTime
				,@CleanupMode = 'AFTER_BACKUP',@Compress = @Compress,@CopyOnly = 'N',@ChangeBackupType = 'Y',@BackupSoftware = NULL,@CheckSum = 'Y'
				,@Description = @description,@DatabaseOrder = 'DATABASE_SIZE_DESC',@DatabasesInParallel = 'Y',@LogToTable = @log_to_table
				--,@MaxTransferSize=@MaxTransferSize, @Buffercount=@Buffercount, @BlockSize=@BlockSize

		END
	END

	RAISERROR('Completed EXECUTE [dbo].[DatabaseBackup] @Databases = ''%s'',@Directory = ''%s'',@BackupType = ''LOG'',@Verify = ''Y'',@CleanupTime = ''%d''
			,@CleanupMode = ''AFTER_BACKUP'',@Compress = ''Y'',@CopyOnly = ''N'',@ChangeBackupType = ''Y'',@BackupSoftware = NULL,@CheckSum = ''Y''
			,@Description =  ''%s'',@DatabaseOrder = ''DATABASE_SIZE_DESC'',@DatabasesInParallel = ''Y'',@LogToTable = ''%s''
			,@MaxTransferSize=''%d'', @Buffercount=''%d'', @BlockSize=''%d''...',0,1,@DatabaseList,@BackupShare,@CleanupTime,@description,@log_to_table,@MaxTransferSize,@Buffercount,@BlockSize) WITH NOWAIT

END
