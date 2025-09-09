#!/usr/bin/env bash
set -euo pipefail

# Configurable via env
UC_CATALOG="${UC_CATALOG:-local}"
UC_SCHEMA="${UC_SCHEMA:-dev}"
UC_WAREHOUSE="${UC_WAREHOUSE:-/workspace/warehouse}"
UC_DRY_RUN="${UC_DRY_RUN:-false}"

# Ensure warehouse exists and is owned
mkdir -p "${UC_WAREHOUSE}"

# Build SQL for idempotent bootstrap
read -r -d '' SQL <<EOF || true
-- UC-like namespace bootstrap (idempotent)
CREATE NAMESPACE IF NOT EXISTS ${UC_CATALOG}.${UC_SCHEMA};
-- Optional: a smoke-test table to validate end-to-end
CREATE TABLE IF NOT EXISTS ${UC_CATALOG}.${UC_SCHEMA}.uc_smoke_test (id INT, name STRING) USING delta;
MERGE INTO ${UC_CATALOG}.${UC_SCHEMA}.uc_smoke_test AS t
USING (SELECT 1 AS id, 'ok' AS name) AS s
ON t.id = s.id
WHEN NOT MATCHED THEN INSERT (id, name) VALUES (s.id, s.name);
EOF

echo "[uc-bootstrap] Catalog: ${UC_CATALOG}"
echo "[uc-bootstrap] Schema:  ${UC_SCHEMA}"
echo "[uc-bootstrap] Warehouse: ${UC_WAREHOUSE}"
echo "[uc-bootstrap] Dry run: ${UC_DRY_RUN}"
echo "[uc-bootstrap] SQL to run:"
echo "----------------------------------------"
echo "${SQL}"
echo "----------------------------------------"

if [ "${UC_DRY_RUN}" = "true" ]; then
  echo "[uc-bootstrap] Dry run enabled, not executing."
  exit 0
fi

# Run with spark-sql so it respects spark-defaults.conf
spark-sql -S -e "${SQL}"
echo "[uc-bootstrap] Completed."
