# ==========================================
# CRANEOPS SPARK - PRODUCTION IMAGE
# ==========================================
# Base: Official Apache Spark 3.5.0 (Contains Hadoop 3.3.4)
# Drivers: Azure Storage (ABFSS) + MSSQL JDBC + Delta Lake
# ==========================================

FROM apache/spark:3.5.0

USER root

# 1. Install Python Dependencies
# We need 'azure-storage-blob' and 'azure-identity' for the script's logic,
# 'pandas' for any local data manipulation, and 'delta-spark' for Lakehouse capabilities.
RUN pip install --no-cache-dir \
    azure-storage-blob \
    azure-identity \
    pandas \
    pyarrow \
    delta-spark==3.1.0

# 2. Download Missing JARs (The "Bridge" between Spark, Azure, and Delta)
# We download these directly into the Spark JARs folder so they are automatically on the classpath.
WORKDIR /opt/spark/jars

RUN set -ex; \
    # --- AZURE STORAGE (Enables abfss:// protocol) ---
    # Matches Hadoop 3.3.4 (which is inside Spark 3.5.0)
    curl -O https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-azure/3.3.4/hadoop-azure-3.3.4.jar; \
    # Required dependency for hadoop-azure
    curl -O https://repo1.maven.org/maven2/com/microsoft/azure/azure-storage/8.6.6/azure-storage-8.6.6.jar; \
    \
    # --- SQL SERVER (Enables jdbc:sqlserver:// protocol) ---
    curl -O https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.4.2.jre11/mssql-jdbc-12.4.2.jre11.jar; \
    \
    # --- DELTA LAKE (Enables ACID transactions & Lakehouse) ---
    # Matches Spark 3.5.x compatibility
    curl -O https://repo1.maven.org/maven2/io/delta/delta-spark_2.12/3.1.0/delta-spark_2.12-3.1.0.jar; \
    curl -O https://repo1.maven.org/maven2/io/delta/delta-storage/3.1.0/delta-storage-3.1.0.jar

# 3. Setup Work Directory
WORKDIR /opt/spark/work-dir

# 4. Copy the ETL Script
# (The Makefile copies this from src/processing to infra/spark context before build)
COPY etl_job.py .

# 5. Security: Switch back to non-root user
USER spark

# 6. Verify JARs exist (Debugging step)
RUN ls -la /opt/spark/jars/hadoop-azure* /opt/spark/jars/mssql-jdbc* /opt/spark/jars/delta-*