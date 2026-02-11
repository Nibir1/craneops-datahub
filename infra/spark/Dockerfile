# ==========================================
# CRANEOPS SPARK - PRODUCTION IMAGE
# ==========================================
# Extends official Spark with Azure Storage JARs and Python
# Tag: craneops/spark-azure:3.5.7-v1

FROM spark:3.5.7-scala2.12-java11-ubuntu

USER root

# Install Python 3.11 and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3-pip \
    python3.11-venv \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && ln -sf /usr/bin/python3 /usr/bin/python

# Install PySpark and pandas
RUN pip3 install --no-cache-dir \
    pyspark==3.5.1 \
    pandas>=2.0.0

# Create directories
RUN mkdir -p /opt/spark/jars/azure /opt/spark/work-dir /tmp/.ivy2 /data && \
    chown -R spark:spark /opt/spark/work-dir /tmp/.ivy2 /data

# Download Azure/Hadoop dependencies
RUN set -eux; \
    cd /opt/spark/jars/azure; \
    \
    curl -fsSL -o hadoop-azure-3.3.4.jar \
    "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-azure/3.3.4/hadoop-azure-3.3.4.jar"; \
    \
    curl -fsSL -o azure-storage-8.6.6.jar \
    "https://repo1.maven.org/maven2/com/microsoft/azure/azure-storage/8.6.6/azure-storage-8.6.6.jar"; \
    \
    curl -fsSL -o httpclient-4.5.13.jar \
    "https://repo1.maven.org/maven2/org/apache/httpcomponents/httpclient/4.5.13/httpclient-4.5.13.jar"; \
    \
    curl -fsSL -o httpcore-4.4.13.jar \
    "https://repo1.maven.org/maven2/org/apache/httpcomponents/httpcore/4.4.13/httpcore-4.4.13.jar"; \
    \
    curl -fsSL -o commons-codec-1.15.jar \
    "https://repo1.maven.org/maven2/commons-codec/commons-codec/1.15/commons-codec-1.15.jar"; \
    \
    curl -fsSL -o jackson-datatype-jsr310-2.15.2.jar \
    "https://repo1.maven.org/maven2/com/fasterxml/jackson/datatype/jackson-datatype-jsr310/2.15.2/jackson-datatype-jsr310-2.15.2.jar"; \
    \
    curl -fsSL -o jetty-util-ajax-9.4.53.v20231009.jar \
    "https://repo1.maven.org/maven2/org/eclipse/jetty/jetty-util-ajax/9.4.53.v20231009/jetty-util-ajax-9.4.53.v20231009.jar"; \
    \
    curl -fsSL -o jetty-util-9.4.53.v20231009.jar \
    "https://repo1.maven.org/maven2/org/eclipse/jetty/jetty-util/9.4.53.v20231009/jetty-util-9.4.53.v20231009.jar"; \
    \
    curl -fsSL -o jetty-http-9.4.53.v20231009.jar \
    "https://repo1.maven.org/maven2/org/eclipse/jetty/jetty-http/9.4.53.v20231009/jetty-http-9.4.53.v20231009.jar"; \
    \
    curl -fsSL -o jetty-io-9.4.53.v20231009.jar \
    "https://repo1.maven.org/maven2/org/eclipse/jetty/jetty-io/9.4.53.v20231009/jetty-io-9.4.53.v20231009.jar"; \
    \
    curl -fsSL -o jetty-client-9.4.53.v20231009.jar \
    "https://repo1.maven.org/maven2/org/eclipse/jetty/jetty-client/9.4.53.v20231009/jetty-client-9.4.53.v20231009.jar"; \
    \
    for jar in *.jar; do \
    echo "Verifying: $jar"; \
    jar tf "$jar" > /dev/null 2>&1 || { echo "Invalid JAR: $jar"; exit 1; }; \
    done; \
    \
    chown -R spark:spark /opt/spark/jars/azure && \
    chmod 644 /opt/spark/jars/azure/*.jar

# Environment variables
ENV SPARK_EXTRA_CLASSPATH="/opt/spark/jars/azure/*"
ENV IVY_HOME="/tmp/.ivy2"
ENV PYSPARK_PYTHON=/usr/bin/python3
ENV PYSPARK_DRIVER_PYTHON=/usr/bin/python3

USER spark
WORKDIR /opt/spark/work-dir

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/ || exit 1

LABEL maintainer="craneops-team" \
    version="3.5.7-v1" \
    description="Spark 3.5.7 with Azure Blob Storage and Python for CraneOps"