USE [DBA]
GO
/****** Object:  StoredProcedure [maintenance].[full_backup]    Script Date: 2/13/2025 12:32:50 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:			Steve Rezhener
-- Create date: 	04/04/2025
-- Description:		Runs full backup using Ola Hallenger script
-- EXEC DBA.maintenance.full_backup 
-- EXEC DBA.maintenance.full_backup @debug_only='Y',@log_to_table='N'
-- =============================================
CREATE OR ALTER                     PROCEDURE [maintenance].[full_backup]
	@debug_only							CHAR(1)			= 'N'
	,@log_to_table						CHAR(1)			= 'Y'
	,@specific_database_name			NVARCHAR(50)	= NULL
	,@specific_backup_path				NVARCHAR(500)	= NULL 
	,@limit_to_one_file					CHAR(1)			= 'N'
	,@copy_only							CHAR(1)			= 'N'
AS
BEGIN

	SET NOCOUNT ON;

	--IF EXISTS (SELECT id FROM DBA.[Maintenance].[Configuration]	WHERE	SettingName = 'CleanupTime')
	--	UPDATE	DBA.[Maintenance].[Configuration]	SET		SettingName = 'CleanupTimeHours'	WHERE	SettingName = 'CleanupTime'

	DECLARE @Version VARCHAR(10) = '1.06' --- added compress Y/N condition

	DECLARE @description AS VARCHAR(50) = 'Weekly Full Backup'
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
		SET @NumberOfFiles = CASE WHEN @limit_to_one_file='N' THEN (SELECT case when cpu_count >=8 THEN 8 ELSE cpu_count END FROM master.sys.dm_os_sys_info) ELSE 1 END
		SET @CleanupTime = (SELECT	CAST([SettingValue] AS INT) FROM DBA.[Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'CleanupTimeHours')
		SET @BackupShare = (SELECT [mc].[SettingValue] FROM DBA.[Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'BackupPath')
		SET @LocalBackup = (SELECT [mc].[SettingValue] FROM DBA.[Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'MirrorDirectory')
		SET @EnableBackupMirroring = (SELECT [mc].[SettingValue] FROM DBA.[Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'BackupMirroring')
		SET @OtherSystemDatabases = (SELECT [SettingValue] from Maintenance.Configuration where 1=1 AND SettingName='OtherSystemDatabases')

		--backup configurations
		SET @MaxTransferSize = (SELECT CAST([SettingValue] AS INT) FROM DBA.[Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'BackupMaxTransferSize')
		SET @Buffercount = (SELECT CAST([SettingValue] AS INT) FROM DBA.[Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'BackupBuffercount')
		SET @BlockSize = (SELECT CAST([SettingValue] AS INT) FROM DBA.[Maintenance].[Configuration] AS [mc] WHERE [mc].[SettingName] = 'BackupBlockSize') 

		-- FullBackupExcludeDatabaseList, DiffBackupExcludedatabaselist, LogBackupExcludedatabaselist, OutofScheduleFullBackupExcludedatabaselist
		SET @excludedatabaselist = (SELECT [SettingValue] from DBA.[Maintenance].[Configuration] where 1=1 AND SettingName='FullBackupExcludeDatabaseList')

		IF ISNULL(@specific_backup_path,'')!=''		SET @BackupShare = @specific_backup_path
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

		IF CHARINDEX(@Edition,'Standard',1) >0 AND CHARINDEX(@Edition,'Developer',1) >0 AND CHARINDEX(@Edition,'Enterprise',1) >0
			SET @Compress='Y'
		ELSE
			SET @Compress='N'

	END

	RAISERROR('Starting %s on [%s] databases to [%s] using @MaxTransferSize=%d,@Buffercount=%d,@BlockSize=%d...',0,1,@description,@DatabaseList,@BackupShare,@MaxTransferSize,@Buffercount,@BlockSize) WITH NOWAIT

	IF @debug_only='N'
	BEGIN

		EXECUTE [dbo].[DatabaseBackup]
			@Databases = @DatabaseList,@Directory = @BackupShare,@BackupType = 'FULL',@Verify = 'Y',@CleanupTime = @CleanupTime
			,@CleanupMode = 'AFTER_BACKUP',@Compress = @Compress,@CopyOnly = @copy_only, @ChangeBackupType = 'Y',@BackupSoftware = NULL,@CheckSum = 'Y'
			,@Description = @description,@DatabaseOrder = 'DATABASE_SIZE_DESC',@DatabasesInParallel = 'Y',@LogToTable = @log_to_table
			,@MaxTransferSize=@MaxTransferSize, @Buffercount=@Buffercount, @BlockSize=@BlockSize
			,@NumberOfFiles=@NumberOfFiles,@MinBackupSizeForMultipleFiles = 10000

		RAISERROR('Completed %s on [%s] databases to [%s] using @MaxTransferSize=%d,@Buffercount=%d,@BlockSize=%d !',0,1,@description,@DatabaseList,@BackupShare,@MaxTransferSize,@Buffercount,@BlockSize) WITH NOWAIT

	END
	ELSE
	BEGIN
		RAISERROR('Debug only - Bypassing %s on [%s] databases to [%s]!',0,1,@description,@DatabaseList,@BackupShare) WITH NOWAIT
	END
	
	SET @DatabaseList = 'SYSTEM_DATABASES'
	RAISERROR('Starting %s on [%s] databases to [%s] with @MaxTransferSize=%d,@Buffercount=%d,@BlockSize=%d...',0,1,@description,@DatabaseList,@BackupShare,@MaxTransferSize,@Buffercount,@BlockSize) WITH NOWAIT

	IF @debug_only='N' AND ISNULL(@specific_database_name,'')=''
	BEGIN
	
		EXECUTE [dbo].[DatabaseBackup]	@Databases = @DatabaseList,@Directory = @BackupShare,@BackupType = 'FULL',@Verify = 'Y',@CleanupTime = @CleanupTime	
			,@CleanupMode = 'AFTER_BACKUP',@Compress = @Compress, @CopyOnly = 'N',@ChangeBackupType = 'N',@BackupSoftware = NULL,@CheckSum = 'Y'
			,@Description = @description,@DatabaseOrder = 'DATABASE_SIZE_DESC',@DatabasesInParallel = 'Y',@LogToTable = @log_to_table
			,@MaxTransferSize=@MaxTransferSize, @Buffercount=@Buffercount, @BlockSize=@BlockSize
			,@NumberOfFiles=@NumberOfFiles,@MinBackupSizeForMultipleFiles = 10000

		RAISERROR('Completed %s on [%s] databases to [%s] with @MaxTransferSize=%d,@Buffercount=%d,@BlockSize=%d!',0,1,@description,@DatabaseList,@BackupShare,@MaxTransferSize,@Buffercount,@BlockSize) WITH NOWAIT

	END
	ELSE
	BEGIN
		RAISERROR('Debug only - Bypassing %s on [%s] databases to [%s]!',0,1,@description,@DatabaseList,@BackupShare) WITH NOWAIT
	END

	
	/*
	IF ISNULL(@EnableBackupMirroring,'N')	!= 'N'
	
		BEGIN
		
			RAISERROR('Completed Full Backup on [%s] user databases to [%s]!',0,1,@DatabaseList,@LocalBackup) WITH NOWAIT
			
			SET @local_backup_files = @LocalBackup + '\*.bak'
			RAISERROR('Copying [%s] to [%s] ...',0,1,@local_backup_files,@BackupShare) WITH NOWAIT
			EXEC master.sys.xp_copy_files @local_backup_files, @BackupShare
			RAISERROR('Copied [%s] to [%s] ...',0,1,@local_backup_files,@BackupShare) WITH NOWAIT

		END

	END
	*/
	
END
