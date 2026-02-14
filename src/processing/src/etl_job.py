import os
import sys
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, from_json, to_timestamp, window, avg, max as spark_max, count, sum as spark_sum, when
from pyspark.sql.types import StructType, StructField, StringType, DoubleType, LongType
from delta.tables import DeltaTable # <-- NEW: Delta Lake Import

def get_spark_session(app_name="CraneOps-Lakehouse-ETL"):
    """
    Creates a SparkSession configured for either Local or Cloud execution,
    now enhanced with Delta Lake capabilities.
    """
    storage_account = os.getenv("AZURE_STORAGE_ACCOUNT")
    storage_key = os.getenv("AZURE_STORAGE_KEY")
    
    # NEW: Inject Delta Lake configurations into the Spark builder
    builder = SparkSession.builder.appName(app_name) \
        .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension") \
        .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog")
    
    # CLOUD CONFIGURATION (If Env Vars exist)
    if storage_account and storage_key:
        print(f"Configuring Spark for Azure Cloud (Account: {storage_account})")
        builder = builder \
            .config(f"spark.hadoop.fs.azure.account.key.{storage_account}.dfs.core.windows.net", storage_key)
    else:
        print("Configuring Spark for Local/Azurite with Delta Lake")
    
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
        SILVER_PATH = f"abfss://telemetry-silver@{ACCOUNT}.dfs.core.windows.net/delta/crane_events"
        GOLD_PATH = f"abfss://telemetry-gold@{ACCOUNT}.dfs.core.windows.net/delta/daily_stats"
    else:
        # Local Azurite Path
        RAW_PATH = "abfss://telemetry-raw@devstoreaccount1.dfs.core.windows.net/"
        SILVER_PATH = "abfss://telemetry-silver@devstoreaccount1.dfs.core.windows.net/delta/crane_events"
        GOLD_PATH = "abfss://telemetry-gold@devstoreaccount1.dfs.core.windows.net/delta/daily_stats"

    # SQL Configuration
    SQL_HOST = os.getenv("SQL_SERVER_HOST", "sqlserver")
    SQL_USER = os.getenv("SQL_SERVER_USER", "sa")
    SQL_PASS = os.getenv("SQL_SERVER_PASSWORD", "YourStrong!Passw0rd")
    
    jdbc_url = f"jdbc:sqlserver://{SQL_HOST}:1433;databaseName=CraneData;encrypt=true;trustServerCertificate=true;"

    print(f"Starting Lakehouse ETL Job...")
    print(f"Reading from: {RAW_PATH}")

    # ------------------------------------------------------------------
    # 2. READ (Bronze Layer)
    # ------------------------------------------------------------------
    schema = StructType([
        StructField("crane_id", StringType(), True),
        StructField("lift_weight_kg", DoubleType(), True),
        StructField("motor_temp_c", DoubleType(), True),
        StructField("timestamp", StringType(), True)
    ])

    try:
        df_raw = spark.read.schema(schema).json(RAW_PATH + "*/*/*/*.json")
        if df_raw.rdd.isEmpty():
            print("No data found in Bronze layer. Exiting.")
            sys.exit(0)
    except Exception as e:
        print(f"Error reading Bronze: {e}")
        sys.exit(1)

    # ------------------------------------------------------------------
    # 3. TRANSFORM & UPSERT (Silver Layer - Delta)
    # ------------------------------------------------------------------
    print("Processing Silver Layer (Cleansing & Deduplication)...")
    df_silver = df_raw \
        .withColumn("event_ts", to_timestamp(col("timestamp"))) \
        .filter(col("lift_weight_kg") >= 0) \
        .filter(col("lift_weight_kg").isNotNull()) \
        .filter(col("crane_id").isNotNull()) \
        .dropDuplicates(["crane_id", "timestamp"]) # Data Quality Guardrail

    # UPSERT Logic for Silver
    if DeltaTable.isDeltaTable(spark, SILVER_PATH):
        silverTable = DeltaTable.forPath(spark, SILVER_PATH)
        silverTable.alias("old").merge(
            df_silver.alias("new"),
            "old.crane_id = new.crane_id AND old.timestamp = new.timestamp"
        ).whenNotMatchedInsertAll().execute()
    else:
        df_silver.write.format("delta").mode("overwrite").save(SILVER_PATH)

    # Read back the unified Silver table for accurate Gold aggregations
    df_unified_silver = spark.read.format("delta").load(SILVER_PATH)

    # ------------------------------------------------------------------
    # 4. AGGREGATE & UPSERT (Gold Layer - Delta)
    # ------------------------------------------------------------------
    print("Processing Gold Layer (Aggregating KPIs)...")
    df_gold = df_unified_silver \
        .groupBy(
            col("crane_id").alias("CraneID"), 
            window(col("event_ts"), "1 day").alias("time_window")
        ) \
        .agg(
            count("*").alias("TotalLifts"),
            avg("lift_weight_kg").alias("AvgLiftWeightKg"),
            spark_max("motor_temp_c").alias("MaxMotorTempC"),
            spark_sum(when(col("motor_temp_c") > 100, 1).otherwise(0)).alias("OverheatEvents") # FIX: Accurate overheat count
        ) \
        .select(
            col("time_window.start").cast("date").alias("StatDate"),
            col("CraneID"),
            col("TotalLifts"),
            col("AvgLiftWeightKg"),
            col("MaxMotorTempC"),
            col("OverheatEvents")
        )

    # UPSERT Logic for Gold
    if DeltaTable.isDeltaTable(spark, GOLD_PATH):
        goldTable = DeltaTable.forPath(spark, GOLD_PATH)
        goldTable.alias("old").merge(
            df_gold.alias("new"),
            "old.CraneID = new.CraneID AND old.StatDate = new.StatDate"
        ).whenMatchedUpdateAll().whenNotMatchedInsertAll().execute()
    else:
        df_gold.write.format("delta").mode("overwrite").save(GOLD_PATH)

    # Read the final state of today's Gold data to push to SQL
    df_final_gold = spark.read.format("delta").load(GOLD_PATH)

    # ------------------------------------------------------------------
    # 5. SERVE (Azure SQL)
    # ------------------------------------------------------------------
    print(f"Writing aggregates to SQL Server: {SQL_HOST}...")
    
    try:
        # Note: In a true 100% production environment, you would use a SQL MERGE query here 
        # to prevent duplicate rows in SQL if the Spark job runs twice a day. 
        # For now, we continue appending the processed Delta stream.
        df_final_gold.write \
            .format("jdbc") \
            .option("url", jdbc_url) \
            .option("dbtable", "DailyStats") \
            .option("user", SQL_USER) \
            .option("password", SQL_PASS) \
            .option("driver", "com.microsoft.sqlserver.jdbc.SQLServerDriver") \
            .mode("append") \
            .save()
        print("✅ Lakehouse ETL Job Completed Successfully!")
    except Exception as e:
        print(f"❌ Failed to write to SQL: {e}")
        sys.exit(1)

    spark.stop()

if __name__ == "__main__":
    main()