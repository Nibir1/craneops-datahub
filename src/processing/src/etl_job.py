import os
import sys
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, from_json, to_timestamp, window, avg, max as spark_max, count, lit
from pyspark.sql.types import StructType, StructField, StringType, DoubleType, LongType

def get_spark_session(app_name="CraneOps-ETL"):
    """
    Creates a SparkSession configured for either Local or Cloud execution.
    """
    storage_account = os.getenv("AZURE_STORAGE_ACCOUNT")
    storage_key = os.getenv("AZURE_STORAGE_KEY")
    
    builder = SparkSession.builder.appName(app_name)
    
    # CLOUD CONFIGURATION (If Env Vars exist)
    if storage_account and storage_key:
        print(f"☁️  Configuring Spark for Azure Cloud (Account: {storage_account})")
        builder = builder \
            .config(f"spark.hadoop.fs.azure.account.key.{storage_account}.dfs.core.windows.net", storage_key)
    else:
        print("💻 Configuring Spark for Local/Azurite")
    
    return builder.getOrCreate()

def main():
    spark = get_spark_session()
    spark.sparkContext.setLogLevel("WARN")

    # ------------------------------------------------------------------
    # 1. CONFIGURATION (Load from Env Vars)
    # ------------------------------------------------------------------
    IS_CLOUD = os.getenv("AZURE_STORAGE_ACCOUNT") is not None
    
    # Storage Paths
    if IS_CLOUD:
        # ABFSS format for Real Azure Data Lake
        ACCOUNT = os.getenv("AZURE_STORAGE_ACCOUNT")
        RAW_PATH = f"abfss://telemetry-raw@{ACCOUNT}.dfs.core.windows.net/"
        GOLD_PATH = f"abfss://telemetry-gold@{ACCOUNT}.dfs.core.windows.net/daily_stats"
    else:
        # Local Azurite Path
        RAW_PATH = "abfss://telemetry-raw@devstoreaccount1.dfs.core.windows.net/"
        GOLD_PATH = "/data/telemetry-gold/daily_stats"

    # SQL Configuration
    SQL_HOST = os.getenv("SQL_SERVER_HOST", "sqlserver")
    SQL_USER = os.getenv("SQL_SERVER_USER", "sa")
    SQL_PASS = os.getenv("SQL_SERVER_PASSWORD", "YourStrong!Passw0rd")
    
    # Construct JDBC URL
    # Cloud uses standard SQL Server port 1433 and DNS
    jdbc_url = f"jdbc:sqlserver://{SQL_HOST}:1433;databaseName=CraneData;encrypt=true;trustServerCertificate=true;"

    print(f"🚀 Starting ETL Job...")
    print(f"📂 Reading from: {RAW_PATH}")
    print(f"💾 Writing to SQL: {SQL_HOST}")

    # ------------------------------------------------------------------
    # 2. READ (Bronze)
    # ------------------------------------------------------------------
    # Define Schema (Strict Schema Enforcement)
    schema = StructType([
        StructField("crane_id", StringType(), True),
        StructField("lift_weight_kg", DoubleType(), True),
        StructField("motor_temp_c", DoubleType(), True),
        StructField("timestamp", StringType(), True) # Read as string, parse later
    ])

    # Read JSONs recursively
    df_raw = spark.read.schema(schema).json(RAW_PATH + "*/*/*/*.json")

    # ------------------------------------------------------------------
    # 3. TRANSFORM (Silver)
    # ------------------------------------------------------------------
    df_silver = df_raw \
        .withColumn("event_ts", to_timestamp(col("timestamp"))) \
        .filter(col("lift_weight_kg") >= 0) \
        .filter(col("lift_weight_kg").isNotNull()) \
        .filter(col("crane_id").isNotNull())

    # ------------------------------------------------------------------
    # 4. AGGREGATE (Gold)
    # ------------------------------------------------------------------
    # Group by Crane and Day
    df_gold = df_silver \
        .groupBy(
            col("crane_id").alias("CraneID"), 
            window(col("event_ts"), "1 day").alias("time_window")
        ) \
        .agg(
            count("*").alias("TotalLifts"),
            avg("lift_weight_kg").alias("AvgLiftWeightKg"),
            spark_max("motor_temp_c").alias("MaxMotorTempC"),
            count(col("motor_temp_c") > 100).alias("OverheatEvents") # Simple logic
        ) \
        .select(
            col("time_window.start").cast("date").alias("StatDate"),
            col("CraneID"),
            col("TotalLifts"),
            col("AvgLiftWeightKg"),
            col("MaxMotorTempC"),
            col("OverheatEvents")
        )

    # ------------------------------------------------------------------
    # 5. WRITE (SQL Server)
    # ------------------------------------------------------------------
    print("💾 Writing aggregates to SQL Server...")
    
    try:
        df_gold.write \
            .format("jdbc") \
            .option("url", jdbc_url) \
            .option("dbtable", "DailyStats") \
            .option("user", SQL_USER) \
            .option("password", SQL_PASS) \
            .option("driver", "com.microsoft.sqlserver.jdbc.SQLServerDriver") \
            .mode("append") \
            .save()
        print("✅ ETL Job Completed Successfully!")
    except Exception as e:
        print(f"❌ Failed to write to SQL: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()