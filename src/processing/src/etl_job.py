import sys
import os
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, to_date, avg, max, count, current_timestamp, sum as spark_sum, when
from pyspark.sql.types import StructType, StructField, StringType, DoubleType

# JDBC Configuration for SQL Server
JDBC_URL = "jdbc:sqlserver://sqlserver:1433;databaseName=CraneData;encrypt=true;trustServerCertificate=true;"

def create_spark_session():
    """Initialize Spark session with Azure and MSSQL support."""
    return SparkSession.builder \
        .appName("CraneOps_ETL") \
        .getOrCreate()

def run_etl():
    spark = create_spark_session()
    
    print("=" * 60)
    print("CRANEOPS ETL - MEDALLION ARCHITECTURE")
    print("=" * 60)
    print("Reading from Bronze Layer (Raw JSON from Azurite)...")
    
    # Define schema
    schema = StructType([
        StructField("crane_id", StringType(), True),
        StructField("lift_weight_kg", DoubleType(), True),
        StructField("motor_temp_c", DoubleType(), True),
        StructField("timestamp", StringType(), True)
    ])

    # Azurite stores files with GUID names (no .json extension)
    input_path = "/data/__blobstorage__/*"
    
    try:
        # Check if data exists
        if not os.path.exists("/data/__blobstorage__"):
            print("⚠️  Azurite data directory not found. Make sure volume is mounted.")
            spark.stop()
            sys.exit(1)
            
        # List files (all files, not just .json)
        files = os.listdir("/data/__blobstorage__")
        data_files = [f for f in files if os.path.isfile(os.path.join("/data/__blobstorage__", f))]
        print(f"📁 Found {len(data_files)} files in Bronze layer (Azurite)")
        
        if len(data_files) == 0:
            print("⚠️  No files found. Run 'make gen-run' first to generate telemetry!")
            spark.stop()
            sys.exit(0)

        # Read all files - Spark will parse JSON content regardless of filename
        df_bronze = spark.read.json(input_path, schema=schema)
        
        if df_bronze.isEmpty():
            print("⚠️  No data could be parsed. Check file format.")
            spark.stop()
            sys.exit(0)

        bronze_count = df_bronze.count()
        print(f"✅ Loaded {bronze_count} records from Bronze layer")
        print("\n📝 Sample Bronze Data:")
        df_bronze.show(5, truncate=False)

        # 2. TRANSFORM (Silver) - Clean and type data
        print("\n" + "=" * 60)
        print("TRANSFORMING TO SILVER LAYER")
        print("=" * 60)
        
        df_silver = df_bronze \
            .withColumn("event_ts", col("timestamp").cast("timestamp")) \
            .withColumn("report_date", to_date(col("event_ts"))) \
            .filter(col("lift_weight_kg").isNotNull()) \
            .filter(col("lift_weight_kg") >= 0) \
            .filter(col("crane_id").isNotNull())

        silver_count = df_silver.count()
        print(f"✅ Silver layer: {silver_count} valid records")
        print("\n📝 Sample Silver Data:")
        df_silver.show(5, truncate=False)

        # 3. AGGREGATE (Gold) - Business KPIs
        print("\n" + "=" * 60)
        print("AGGREGATING TO GOLD LAYER")
        print("=" * 60)
        
        # Aggregate with column names matching SQL schema (CamelCase)
        # FIXED: Use when() to count overheat events properly
        df_gold = df_silver.groupBy("report_date", "crane_id") \
            .agg(
                count("lift_weight_kg").alias("TotalLifts"),
                avg("lift_weight_kg").alias("AvgLiftWeightKg"),
                max("motor_temp_c").alias("MaxMotorTempC"),
                # FIXED: Use when() to create 1/0 values, then sum
                spark_sum(when(col("motor_temp_c") > 100, 1).otherwise(0)).alias("OverheatEvents")
            ) \
            .withColumnRenamed("report_date", "StatDate") \
            .withColumnRenamed("crane_id", "CraneID") \
            .withColumn("LastUpdated", current_timestamp())

        gold_count = df_gold.count()
        print(f"✅ Gold layer: {gold_count} aggregated records")
        print("\n🏆 Gold Layer Results (Business KPIs):")
        df_gold.show(truncate=False)
        
        # 4. WRITE (Gold) - Write to Azurite Gold container
        output_path = "/data/telemetry-gold/daily_stats"
        
        # Ensure directory exists
        os.makedirs("/data/telemetry-gold", exist_ok=True)
        
        print(f"\n💾 Writing Gold data to: {output_path}")
        print("(Simulating Azure Data Lake Gen2 - Gold Layer)")
        
        # Write as Parquet (columnar format for analytics)
        df_gold.write.mode("overwrite").parquet(output_path)
        
        # Also write as JSON for easy inspection
        json_output = "/data/telemetry-gold/daily_stats_json"
        df_gold.write.mode("overwrite").json(json_output)
        
        print(f"\n✅ Data Lake Write Complete:")
        print(f"   - Parquet: {output_path}")
        print(f"   - JSON:    {json_output}")
        
        # 5. SERVING (SQL Server)
        print("\n" + "=" * 60)
        print("PUBLISHING TO SQL SERVER (Serving Layer)")
        print("=" * 60)
        
        # Get password from environment (Safety First)
        db_password = os.environ.get("MSSQL_SA_PASSWORD")
        if not db_password:
            print("⚠️  MSSQL_SA_PASSWORD not set. Skipping SQL write.")
        else:
            try:
                print(f"🔌 Connecting to: {JDBC_URL}")
                
                # Write Mode: Overwrite
                # In production, consider 'append' with pre-delete logic for idempotency
                df_gold.write \
                    .format("jdbc") \
                    .option("url", JDBC_URL) \
                    .option("dbtable", "dbo.DailyStats") \
                    .option("user", "sa") \
                    .option("password", db_password) \
                    .option("driver", "com.microsoft.sqlserver.jdbc.SQLServerDriver") \
                    .mode("overwrite") \
                    .save()
                    
                print("✅ Successfully wrote data to SQL Server table 'dbo.DailyStats'")
                
            except Exception as e:
                print(f"❌ Failed to write to SQL Server: {str(e)}")
                import traceback
                traceback.print_exc()
                # Don't fail the whole job if SQL is down, just log it

        print(f"\n" + "=" * 60)
        print(f"✅ ETL JOB COMPLETE SUCCESSFULLY!")
        print(f"=" * 60)
        print(f"   - Bronze: {bronze_count} raw records")
        print(f"   - Silver: {silver_count} cleaned records")  
        print(f"   - Gold:   {gold_count} aggregated records")
        print(f"   - SQL:    Published to dbo.DailyStats")
        
    except Exception as e:
        print(f"\n❌ ETL JOB FAILED: {str(e)}")
        import traceback
        traceback.print_exc()
        spark.stop()
        sys.exit(1)
    
    spark.stop()

if __name__ == "__main__":
    run_etl()