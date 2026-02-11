-- Create the main database
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = 'CraneData')
BEGIN
    CREATE DATABASE CraneData;
END
GO

USE CraneData;
GO

-- Create the DailyStats table (Gold Layer)
-- Stores aggregated crane performance metrics
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[DailyStats]') AND type in (N'U'))
BEGIN
    CREATE TABLE dbo.DailyStats (
        StatDate DATE NOT NULL,
        CraneID VARCHAR(50) NOT NULL,
        TotalLifts INT NOT NULL DEFAULT 0,
        AvgLiftWeightKg FLOAT NOT NULL DEFAULT 0.0,
        MaxMotorTempC FLOAT NOT NULL DEFAULT 0.0,
        OverheatEvents INT NOT NULL DEFAULT 0,
        LastUpdated DATETIME2 DEFAULT GETDATE(),
        PRIMARY KEY (StatDate, CraneID)
    );
END
GO

-- Create a read/write user for the application (Security Best Practice: Don't use SA)
IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = 'crane_user')
BEGIN
    CREATE LOGIN crane_user WITH PASSWORD = 'YourStrong!Passw0rd';
END
GO

IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'crane_user')
BEGIN
    CREATE USER crane_user FOR LOGIN crane_user;
    ALTER ROLE db_datareader ADD MEMBER crane_user;
    ALTER ROLE db_datawriter ADD MEMBER crane_user;
    -- Grant permission to execute stored procedures if added later
    GRANT EXECUTE TO crane_user;
END
GO