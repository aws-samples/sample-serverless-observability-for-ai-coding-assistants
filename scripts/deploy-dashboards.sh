#!/bin/bash
# deploy-dashboards.sh — Push all Claude Code dashboards to Amazon Managed Grafana
#
# Usage:
#   ./deploy-dashboards.sh <GRAFANA_URL> <API_KEY> [ATHENA_DATABASE]
#
# Example:
#   ./deploy-dashboards.sh https://g-abc123.grafana-workspace.us-east-1.amazonaws.com eyJrIjo... claude_code_telemetry_prod
#
# Prerequisites:
#   1. Grafana workspace deployed (terraform apply)
#   2. API key created in Grafana UI (Configuration > API Keys > Add)
#   3. Athena data source configured in Grafana

set -euo pipefail

GRAFANA_URL="${1:?Usage: $0 <GRAFANA_URL> <API_KEY> [ATHENA_DATABASE]}"
API_KEY="${2:?Usage: $0 <GRAFANA_URL> <API_KEY> [ATHENA_DATABASE]}"
ATHENA_DATABASE="${3:-claude_code_telemetry_dev}"
DASHBOARD_DIR="$(cd "$(dirname "$0")/../terraform/dashboards" && pwd)"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "============================================"
echo " Claude Code Telemetry — Dashboard Deployer"
echo "============================================"
echo ""
echo "Grafana:    ${GRAFANA_URL}"
echo "Database:   ${ATHENA_DATABASE}"
echo "Dashboards: ${DASHBOARD_DIR}"
echo ""

# Check connectivity
echo -n "Checking Grafana connectivity... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${API_KEY}" \
  "${GRAFANA_URL}/api/org")

if [ "$HTTP_CODE" != "200" ]; then
  echo -e "${RED}FAILED (HTTP ${HTTP_CODE})${NC}"
  echo "Check your GRAFANA_URL and API_KEY."
  exit 1
fi
echo -e "${GREEN}OK${NC}"
echo ""

# Deploy each dashboard
DEPLOYED=0
FAILED=0

for DASHBOARD_FILE in "${DASHBOARD_DIR}"/*.json; do
  FILENAME=$(basename "$DASHBOARD_FILE")
  TITLE=$(python3 -c "import json; print(json.load(open('${DASHBOARD_FILE}'))['title'])" 2>/dev/null || echo "$FILENAME")

  echo -n "Deploying: ${TITLE} ... "

  # Wrap dashboard JSON in the Grafana API envelope.
  # Write to temp file to avoid shell expansion of Grafana macros ($__timeFrom etc).
  TMPFILE=$(mktemp)
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    dashboard = json.load(f)
dashboard['id'] = None  # let Grafana assign or match by uid
db = sys.argv[2]
for v in dashboard.get('templating', {}).get('list', []):
    if v.get('name') == 'athena_database':
        v['query'] = db
        v['current'] = {'text': db, 'value': db}
payload = {
    'dashboard': dashboard,
    'overwrite': True,
    'message': 'Deployed via deploy-dashboards.sh'
}
with open(sys.argv[3], 'w') as out:
    json.dump(payload, out)
" "${DASHBOARD_FILE}" "${ATHENA_DATABASE}" "${TMPFILE}"

  RESPONSE=$(curl -s -X POST "${GRAFANA_URL}/api/dashboards/db" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d @"${TMPFILE}")
  rm -f "${TMPFILE}"

  STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','ok'))" 2>/dev/null || echo "error")

  if [ "$STATUS" = "success" ] || [ "$STATUS" = "ok" ]; then
    URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('url',''))" 2>/dev/null || echo "")
    echo -e "${GREEN}OK${NC}  →  ${GRAFANA_URL}${URL}"
    DEPLOYED=$((DEPLOYED + 1))
  else
    MSG=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','unknown error'))" 2>/dev/null || echo "$RESPONSE")
    echo -e "${RED}FAILED${NC}  →  ${MSG}"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "============================================"
echo -e " Deployed: ${GREEN}${DEPLOYED}${NC}   Failed: ${RED}${FAILED}${NC}"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
