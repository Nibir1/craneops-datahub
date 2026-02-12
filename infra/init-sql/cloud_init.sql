-- Check if table exists before creating
IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='DailyStats' AND xtype='U')
BEGIN
    PRINT 'Creating DailyStats table...';
    CREATE TABLE DailyStats (
        StatDate DATE NOT NULL,
        CraneID VARCHAR(50) NOT NULL,
        TotalLifts INT,
        AvgLiftWeightKg FLOAT,
        MaxMotorTempC FLOAT,
        OverheatEvents INT,
        LastUpdated DATETIME DEFAULT GETDATE(),
        PRIMARY KEY (StatDate, CraneID)
    );
END
ELSE
BEGIN
    PRINT 'DailyStats table already exists.';
END
GO