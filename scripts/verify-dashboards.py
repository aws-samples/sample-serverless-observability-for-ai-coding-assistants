#!/usr/bin/env python3
"""Verify all Grafana dashboard panels return data.

Usage:
    python3 verify-dashboards.py <GRAFANA_URL> <API_KEY>

Example:
    python3 verify-dashboards.py https://g-abc123.grafana-workspace.us-east-1.amazonaws.com eyJrIjo...
"""

import urllib.request
import json
import glob
import sys
import os

if len(sys.argv) != 3:
    print(
        "Usage: python3 verify-dashboards.py <GRAFANA_URL> <API_KEY>", file=sys.stderr
    )
    sys.exit(2)

GF = sys.argv[1].rstrip("/")
KEY = sys.argv[2]

total_ok = 0
total_fail = 0

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_DIR = os.path.join(SCRIPT_DIR, "..", "terraform", "dashboards")
for f in sorted(glob.glob(os.path.join(DASHBOARD_DIR, "*.json"))):
    with open(f) as fh:
        d = json.load(fh)
    print(f"\n{d['title']}")
    print("-" * 50)
    for p in d.get("panels", []):
        if p.get("type") == "row":
            continue
        ds = p.get("datasource", {})
        if ds.get("type") not in (None, "grafana-athena-datasource"):
            print(
                f"  [{p['type']:10}] {p['title'][:38]:38} SKIP ({ds.get('type', 'unknown')})"
            )
            continue
        for t in p.get("targets", []):
            expr = t.get("expr", "")
            if not expr or "increase(" in expr:
                continue
            try:
                url = f"{GF}/api/datasources/proxy/1/api/v1/query?query={urllib.request.quote(expr)}"
                req = urllib.request.Request(
                    url, headers={"Authorization": f"Bearer {KEY}"}
                )
                resp = json.loads(urllib.request.urlopen(req).read())
                r = resp["data"]["result"]
                if r:
                    total_ok += 1
                    print(
                        f"  [{p['type']:10}] {p['title'][:38]:38} OK ({len(r)} series)"
                    )
                else:
                    total_fail += 1
                    print(f"  [{p['type']:10}] {p['title'][:38]:38} NO DATA")
            except Exception as e:
                total_fail += 1
                print(f"  [{p['type']:10}] {p['title'][:38]:38} ERR: {e}")

print(f"\n{'=' * 50}")
print(f"OK: {total_ok}  |  No Data: {total_fail}")
print(f"{'=' * 50}")
sys.exit(1 if total_fail > 0 else 0)
