#!/usr/bin/env python3
"""Fix dashboard JSON files to be portable (no hardcoded UIDs, databases, or dates).

Transforms:
1. Data source UID -> ${DS_ATHENA} template variable
2. Database name -> ${athena_database} template variable
3. Hardcoded date partition -> dynamic current_date or Grafana time range
4. Adds templating section with DS_ATHENA and athena_database variables
"""

import json
import glob
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_DIR = os.path.join(SCRIPT_DIR, "..", "terraform", "dashboards")

# The hardcoded values to replace
HARDCODED_UID = "dfg79xo95ab5sd"
HARDCODED_DB = "claude_code_telemetry_dev"
HARDCODED_DATE_FILTER = "year=2026 AND month=3 AND day=17"

# Dynamic date filter: covers the Grafana time picker range, including ranges that
# cross a month or year boundary (compares yyyymmdd numbers built from the partitions).
# Uses partition projection integers for efficient S3 scanning
DYNAMIC_DATE_FILTER = (
    "year BETWEEN year($__timeFrom()) AND year($__timeTo()) "
    "AND year * 10000 + month * 100 + day BETWEEN "
    "year($__timeFrom()) * 10000 + month($__timeFrom()) * 100 + day_of_month($__timeFrom()) "
    "AND year($__timeTo()) * 10000 + month($__timeTo()) * 100 + day_of_month($__timeTo())"
)

# Templating section to add to each dashboard
TEMPLATING = {
    "list": [
        {
            "name": "DS_ATHENA",
            "type": "datasource",
            "query": "grafana-athena-datasource",
            "current": {},
            "hide": 0,
            "includeAll": False,
            "multi": False,
            "label": "Athena Data Source",
        },
        {
            "name": "athena_database",
            "type": "constant",
            "query": "claude_code_telemetry_dev",
            "current": {
                "text": "claude_code_telemetry_dev",
                "value": "claude_code_telemetry_dev",
            },
            "hide": 2,  # hidden variable — user sets once
            "label": "Athena Database",
            "description": "Glue database name (e.g. claude_code_telemetry_dev, claude_code_telemetry_prod)",
        },
    ]
}


def fix_dashboard(filepath):
    with open(filepath) as f:
        dashboard = json.load(f)

    # Add templating
    dashboard["templating"] = TEMPLATING

    changes = 0
    for panel in dashboard.get("panels", []):
        if panel.get("type") == "row":
            continue

        # Fix datasource UID
        ds = panel.get("datasource", {})
        if ds.get("uid") == HARDCODED_UID:
            ds["uid"] = "${DS_ATHENA}"
            changes += 1

        # Fix targets
        for target in panel.get("targets", []):
            # Fix connectionArgs database
            conn = target.get("connectionArgs", {})
            if conn.get("database") == HARDCODED_DB:
                conn["database"] = "${athena_database}"
                changes += 1

            # Remove hardcoded region — let the data source config handle it
            if "region" in conn:
                conn["region"] = "__default"
                changes += 1

            # Fix SQL
            sql = target.get("rawSQL", "")
            if sql:
                original = sql
                # Replace database name in FROM clauses
                sql = sql.replace(f"{HARDCODED_DB}.", "${athena_database}.")
                # Replace hardcoded date filter
                sql = sql.replace(HARDCODED_DATE_FILTER, DYNAMIC_DATE_FILTER)
                if sql != original:
                    target["rawSQL"] = sql
                    changes += 1

    with open(filepath, "w") as f:
        json.dump(dashboard, f, indent=2, ensure_ascii=False)
        f.write("\n")

    return changes


if __name__ == "__main__":
    total = 0
    for f in sorted(glob.glob(os.path.join(DASHBOARD_DIR, "*.json"))):
        n = fix_dashboard(f)
        print(f"  {os.path.basename(f)}: {n} changes")
        total += n
    print(f"\nTotal: {total} changes across all dashboards")
