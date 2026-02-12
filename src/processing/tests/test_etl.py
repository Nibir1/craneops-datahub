import pytest
from pyspark.sql import SparkSession
from pyspark.sql.types import StructType, StructField, StringType, DoubleType
from pyspark.sql.functions import col, to_date

# Define Schema for Test Data
SCHEMA = StructType([
    StructField("crane_id", StringType(), True),
    StructField("lift_weight_kg", DoubleType(), True),
    StructField("motor_temp_c", DoubleType(), True),
    StructField("timestamp", StringType(), True)
])

@pytest.fixture(scope="session")
def spark():
    """Creates a local SparkSession for testing."""
    return SparkSession.builder \
        .master("local[1]") \
        .appName("CraneOps_Test") \
        .getOrCreate()

def test_silver_transformation(spark):
    """Test cleaning logic: Remove negative weights, parse dates."""
    
    # 1. Prepare Mock Data (Bronze Layer)
    data = [
        ("CRANE-VALID", 500.0, 60.0, "2024-01-01T10:00:00Z"),
        ("CRANE-BAD-WEIGHT", -50.0, 60.0, "2024-01-01T10:00:00Z"), # Should be filtered
        ("CRANE-NULL", None, 60.0, "2024-01-01T10:00:00Z"),       # Should be filtered
    ]
    
    df_bronze = spark.createDataFrame(data, schema=SCHEMA)

    # 2. Apply Transformation Logic (Simulating etl_job.py logic)
    df_silver = df_bronze \
        .withColumn("event_ts", col("timestamp").cast("timestamp")) \
        .withColumn("report_date", to_date(col("event_ts"))) \
        .filter(col("lift_weight_kg") >= 0) \
        .filter(col("lift_weight_kg").isNotNull())

    # 3. Assertions
    results = df_silver.collect()
    
    # Only 1 valid record should remain
    assert len(results) == 1
    assert results[0]["crane_id"] == "CRANE-VALID"
    assert str(results[0]["report_date"]) == "2024-01-01"

    print("\n✅ Silver Transformation Test Passed!")