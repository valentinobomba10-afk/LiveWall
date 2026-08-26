#!/usr/bin/env python3
"""
LiveWall admin — see how many people use the app, and manage installs.

This stays on YOUR laptop. It is never shipped inside LiveWall, because it uses
the Supabase secret key, which must never reach a user's machine.

Credentials come from the environment, so no secret is ever written to a file:

    export LIVEWALL_SUPABASE_URL="https://xxxxxxxx.supabase.co"
    export LIVEWALL_SUPABASE_SECRET="sb_secret_..."      # rotate the leaked one first

Usage:
    python3 admin.py stats            # how many people are using the app
    python3 admin.py list             # recent installs
    python3 admin.py ban <install_id>
    python3 admin.py unban <install_id>
    python3 admin.py feature <url>    # set a featured wallpaper for everyone
    python3 admin.py feature clear
"""

import json
import os
import sys
import urllib.request
import urllib.parse
from datetime import datetime, timedelta, timezone

URL = os.environ.get("LIVEWALL_SUPABASE_URL", "").rstrip("/")
KEY = os.environ.get("LIVEWALL_SUPABASE_SECRET", "")


def _require_config():
    if not URL or not KEY:
        sys.exit(
            "Set LIVEWALL_SUPABASE_URL and LIVEWALL_SUPABASE_SECRET first.\n"
            "  export LIVEWALL_SUPABASE_URL='https://xxxx.supabase.co'\n"
            "  export LIVEWALL_SUPABASE_SECRET='sb_secret_...'"
        )


def _request(method, path, params=None, body=None, prefer=None):
    _require_config()
    url = f"{URL}/rest/v1/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("apikey", KEY)
    req.add_header("Authorization", f"Bearer {KEY}")
    req.add_header("Content-Type", "application/json")
    if prefer:
        req.add_header("Prefer", prefer)
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else []


def _count(params=None):
    """Exact row count via the Content-Range header."""
    _require_config()
    url = f"{URL}/rest/v1/installs"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, method="HEAD")
    req.add_header("apikey", KEY)
    req.add_header("Authorization", f"Bearer {KEY}")
    req.add_header("Prefer", "count=exact")
    req.add_header("Range-Unit", "items")
    req.add_header("Range", "0-0")
    with urllib.request.urlopen(req, timeout=15) as resp:
        rng = resp.headers.get("Content-Range", "*/0")
        return int(rng.split("/")[-1])


def stats():
    total = _count()
    since_30 = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
    since_7 = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat()
    since_1 = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
    active_30 = _count({"last_seen": f"gte.{since_30}"})
    active_7 = _count({"last_seen": f"gte.{since_7}"})
    active_1 = _count({"last_seen": f"gte.{since_1}"})
    banned = _count({"banned": "eq.true"})

    print("\n  LiveWall — who's using the app")
    print("  " + "-" * 34)
    print(f"  Total installs        {total:>8,}")
    print(f"  Active last 24h       {active_1:>8,}")
    print(f"  Active last 7 days    {active_7:>8,}")
    print(f"  Active last 30 days   {active_30:>8,}")
    if banned:
        print(f"  Banned                {banned:>8,}")

    rows = _request("GET", "installs", {"select": "app_version"})
    if rows:
        versions = {}
        for r in rows:
            versions[r.get("app_version") or "?"] = versions.get(r.get("app_version") or "?", 0) + 1
        print("\n  By version")
        for v, n in sorted(versions.items(), key=lambda x: -x[1]):
            print(f"    {v:<12} {n:>6,}")
    print()


def list_installs():
    rows = _request("GET", "installs", {
        "select": "install_id,app_version,os_version,last_seen,banned",
        "order": "last_seen.desc",
        "limit": "40",
    })
    if not rows:
        print("No installs yet.")
        return
    print(f"\n  {'install_id':<38} {'ver':<7} {'os':<6} {'last seen':<20} banned")
    for r in rows:
        seen = (r.get("last_seen") or "")[:19].replace("T", " ")
        flag = "yes" if r.get("banned") else ""
        print(f"  {r['install_id']:<38} {str(r.get('app_version') or ''):<7} "
              f"{str(r.get('os_version') or ''):<6} {seen:<20} {flag}")
    print()


def set_banned(install_id, value):
    _request("PATCH", "installs", {"install_id": f"eq.{install_id}"},
             body={"banned": value}, prefer="return=minimal")
    print(f"{'Banned' if value else 'Unbanned'} {install_id}")


def feature(url):
    value = None if url == "clear" else url
    # Single-row config table keyed by id=1. See docs/analytics-setup.md.
    _request("POST", "app_config", params={"on_conflict": "id"},
             body={"id": 1, "featured_wallpaper": value},
             prefer="resolution=merge-duplicates,return=minimal")
    print("Featured wallpaper cleared." if value is None else f"Featured wallpaper set to:\n  {value}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd == "stats":
        stats()
    elif cmd == "list":
        list_installs()
    elif cmd == "ban" and len(sys.argv) == 3:
        set_banned(sys.argv[2], True)
    elif cmd == "unban" and len(sys.argv) == 3:
        set_banned(sys.argv[2], False)
    elif cmd == "feature" and len(sys.argv) == 3:
        feature(sys.argv[2])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
