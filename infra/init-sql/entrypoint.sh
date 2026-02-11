#!/bin/bash
set -e

# Start SQL Server in background
echo "Starting SQL Server..."
/opt/mssql/bin/sqlservr &

# Wait for SQL Server to be ready
echo "Waiting for SQL Server to be available..."
for i in {1..60}; do
    if /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" &>/dev/null; then
        echo "SQL Server is ready!"
        break
    fi
    echo "Waiting... attempt $i/60"
    sleep 1
done

# Run initialization scripts
echo "Running initialization scripts..."
for script in /docker-entrypoint-initdb.d/*.sql; do
    if [ -f "$script" ] && [ "$(basename "$script")" != "entrypoint.sh" ]; then
        echo "Executing: $script"
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -i "$script"
    fi
done

echo "Initialization complete. Keeping SQL Server running..."

# Keep container running
wait