# ==========================================
# CRANEOPS SPARK - PRODUCTION IMAGE
# ==========================================
# Base: Official Apache Spark 3.5.0 (Contains Hadoop 3.3.4)
# Drivers: Azure Storage (ABFSS) + MSSQL JDBC + Delta Lake + ODBC 18
# ==========================================

FROM apache/spark:3.5.0

USER root

# 1. Install Microsoft ODBC Driver 18 & System Dependencies
# We need these native libraries so 'pyodbc' can execute our idempotent SQL MERGE statement.
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    apt-transport-https \
    unixodbc-dev \
    g++ \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/20.04/prod focal main" > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y msodbcsql18 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Python Dependencies
# Added 'pyodbc' to handle the Idempotent SQL Upsert
RUN pip install --no-cache-dir \
    azure-storage-blob \
    azure-identity \
    pandas \
    pyarrow \
    delta-spark==3.1.0 \
    pyodbc

# 3. Download Missing JARs (The "Bridge" between Spark, Azure, and Delta)
WORKDIR /opt/spark/jars

RUN set -ex; \
    # --- AZURE STORAGE (Enables abfss:// protocol) ---
    curl -O https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-azure/3.3.4/hadoop-azure-3.3.4.jar ; \
    curl -O https://repo1.maven.org/maven2/com/microsoft/azure/azure-storage/8.6.6/azure-storage-8.6.6.jar ; \
    \
    # --- SQL SERVER (Enables jdbc:sqlserver:// protocol) ---
    curl -O https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.4.2.jre11/mssql-jdbc-12.4.2.jre11.jar ; \
    \
    # --- DELTA LAKE (Enables ACID transactions & Lakehouse) ---
    curl -O https://repo1.maven.org/maven2/io/delta/delta-spark_2.12/3.1.0/delta-spark_2.12-3.1.0.jar ; \
    curl -O https://repo1.maven.org/maven2/io/delta/delta-storage/3.1.0/delta-storage-3.1.0.jar 

# 4. Setup Work Directory
WORKDIR /opt/spark/work-dir

# 5. Copy the ETL Script
COPY etl_job.py .

# 6. Security: Switch back to non-root user
USER spark

# 7. Verify JARs exist (Debugging step)
RUN ls -la /opt/spark/jars/hadoop-azure* /opt/spark/jars/mssql-jdbc* /opt/spark/jars/delta-*