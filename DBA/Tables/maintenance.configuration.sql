
USE [DBA]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


/****** Object:  Table [maintenance].[Configuration]    Script Date: 3/7/2023 11:51:50 AM ******/

CREATE TABLE [maintenance].[Configuration](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[SettingName] [nvarchar](500) NOT NULL,
	[SettingValue] [nvarchar](2000) NOT NULL,
	[created_on_utc] [datetime2](7) NOT NULL,
	[created_on_pst]  AS ((([created_on_utc] AT TIME ZONE 'UTC') AT TIME ZONE 'Pacific Standard Time')),
 CONSTRAINT [PK_SettingName] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY],
 CONSTRAINT [U_SettingName] UNIQUE NONCLUSTERED 
(
	[SettingName] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [maintenance].[Configuration] ADD  CONSTRAINT [DF_MaintenanceConfiguration_created_on_utc]  DEFAULT (getutcdate()) FOR [created_on_utc]
GO
