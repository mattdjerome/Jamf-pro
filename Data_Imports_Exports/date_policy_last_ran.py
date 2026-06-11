#!/usr/bin/env python3
"""
jamf_policy_last_run.py

Queries Jamf Pro Classic API to determine the last time each policy
was executed across all managed computers. Outputs a CSV report sorted
by policy name.

Authenticates using an API Client (OAuth 2.0 client_credentials grant).
Create one in Jamf Pro: Settings -> API roles and clients -> API Clients.

Usage:
    python3 jamf_policy_last_run.py --url https://yourserver.jamfcloud.com \\
        --client-id <id> --client-secret <secret>

    # Only show policies not run in the last 365 days (or never):
    python3 jamf_policy_last_run.py ... --last-run 365

Environment variables:
    JAMF_URL            - e.g. https://yourserver.jamfcloud.com
    JAMF_CLIENT_ID      - API client ID
    JAMF_CLIENT_SECRET  - API client secret

Output:
    jamf_policy_last_run_<timestamp>.csv
"""

import os
import sys
import csv
import json
import time
import threading
import logging
import argparse
import urllib.request
import urllib.error
import urllib.parse
from datetime import datetime, timezone, timedelta
from concurrent.futures import ThreadPoolExecutor, as_completed

# ──────────────────────────────────────────────
# CONFIG — override via env vars or CLI args
# ──────────────────────────────────────────────
DEFAULT_JAMF_URL           = os.environ.get("JAMF_URL",           "https://yourserver.jamfcloud.com")
DEFAULT_JAMF_CLIENT_ID     = os.environ.get("JAMF_CLIENT_ID",     "")
DEFAULT_JAMF_CLIENT_SECRET = os.environ.get("JAMF_CLIENT_SECRET", "")

# Max parallel threads for computer history calls (keep <=10 to avoid rate limits)
MAX_WORKERS = 8

# Retry settings
MAX_RETRIES = 3
RETRY_DELAY = 2  # seconds

# Refresh token this many seconds before it expires (buffer for clock skew + latency)
TOKEN_REFRESH_BUFFER = 30  # seconds

# ──────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)


# ──────────────────────────────────────────────
# TOKEN MANAGER  — thread-safe auto-refresh
# ──────────────────────────────────────────────
class TokenManager:
    """
    Holds the current bearer token and transparently refreshes it before
    it expires. Thread-safe: all worker threads share one instance.

    The Jamf OAuth token typically expires in 60 seconds, which is far
    shorter than the time needed to scan 1,500+ computers. This class
    proactively fetches a new token TOKEN_REFRESH_BUFFER seconds before
    the current one expires, so worker threads always get a valid token.
    """

    def __init__(self, jamf_url: str, client_id: str, client_secret: str):
        self._jamf_url     = jamf_url
        self._client_id    = client_id
        self._client_secret = client_secret
        self._token        = ""
        self._expires_at   = datetime.now(tz=timezone.utc)  # force immediate fetch
        self._lock         = threading.Lock()

    def _fetch(self) -> None:
        """Internal: call the OAuth endpoint and update state. Caller holds the lock."""
        url = f"{self._jamf_url}/api/oauth/token"
        payload = urllib.parse.urlencode({
            "grant_type":    "client_credentials",
            "client_id":     self._client_id,
            "client_secret": self._client_secret,
        }).encode()
        req = urllib.request.Request(
            url,
            data=payload,
            method="POST",
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept":       "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            raise RuntimeError(f"OAuth token request failed (HTTP {e.code}): {body}") from e

        token = data.get("access_token")
        if not token:
            raise RuntimeError(f"OAuth response missing access_token: {data}")

        expires_in = int(data.get("expires_in", 60))
        self._token      = token
        self._expires_at = (
            datetime.now(tz=timezone.utc) + timedelta(seconds=expires_in)
        )
        log.info(
            "Token refreshed. Valid for %s seconds (until %s UTC).",
            expires_in,
            self._expires_at.strftime("%H:%M:%S"),
        )

    @property
    def token(self) -> str:
        """Return a valid token, refreshing proactively if near expiry."""
        now = datetime.now(tz=timezone.utc)
        cutoff = self._expires_at - timedelta(seconds=TOKEN_REFRESH_BUFFER)
        if now >= cutoff:
            with self._lock:
                # Double-check under lock — another thread may have just refreshed
                now = datetime.now(tz=timezone.utc)
                cutoff = self._expires_at - timedelta(seconds=TOKEN_REFRESH_BUFFER)
                if now >= cutoff:
                    self._fetch()
        return self._token


# ──────────────────────────────────────────────
# HTTP HELPER
# ──────────────────────────────────────────────
def api_get(url: str, token_mgr: TokenManager, retries: int = MAX_RETRIES) -> dict | list:
    """
    GET a Classic API endpoint, returning parsed JSON.
    Fetches a fresh token from token_mgr on each attempt so a mid-request
    refresh is handled automatically. Retries on transient errors.
    """
    last_err = None
    for attempt in range(1, retries + 1):
        token = token_mgr.token  # always fresh
        req = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code == 401:
                # Token expired between the check and the request — force refresh
                log.debug("401 on attempt %s — forcing token refresh.", attempt)
                with token_mgr._lock:
                    token_mgr._expires_at = datetime.now(tz=timezone.utc)  # invalidate
                time.sleep(1)
                last_err = e
            elif e.code in (429, 503):
                wait = RETRY_DELAY * attempt
                log.warning(
                    "Rate limited (HTTP %s). Waiting %ss before retry %s/%s...",
                    e.code, wait, attempt, retries,
                )
                time.sleep(wait)
                last_err = e
            elif e.code == 404:
                return {}  # Computer may have been deleted
            else:
                raise
        except (urllib.error.URLError, TimeoutError) as e:
            log.warning("Network error on attempt %s/%s: %s", attempt, retries, e)
            time.sleep(RETRY_DELAY * attempt)
            last_err = e
    raise RuntimeError(f"Failed after {retries} retries: {last_err}") from last_err


# ──────────────────────────────────────────────
# JAMF DATA FETCHERS
# ──────────────────────────────────────────────
def get_all_policies(jamf_url: str, token_mgr: TokenManager) -> list[dict]:
    """Return list of {id, name} for all policies."""
    url = f"{jamf_url}/JSSResource/policies"
    data = api_get(url, token_mgr)
    policies = data.get("policies", [])
    log.info("Found %d policies.", len(policies))
    return policies


def get_all_computer_ids(jamf_url: str, token_mgr: TokenManager) -> list[int]:
    """Return list of all computer IDs."""
    url = f"{jamf_url}/JSSResource/computers"
    data = api_get(url, token_mgr)
    computers = data.get("computers", [])
    ids = [c["id"] for c in computers]
    log.info("Found %d computers.", len(ids))
    return ids


def get_policy_logs_for_computer(
    jamf_url: str, token_mgr: TokenManager, computer_id: int
) -> list[dict]:
    """
    Return the PolicyLogs subset for a single computer.
    Each entry:
        {
          "policy_id": 42,
          "policy_name": "Install Rosetta 2",
          "username": "jdoe",
          "date_completed_utc": "2024-03-14T22:45:22.000+0000",
          "status": "Completed"
        }
    """
    url = (
        f"{jamf_url}/JSSResource/computerhistory"
        f"/id/{computer_id}/subset/PolicyLogs"
    )
    data = api_get(url, token_mgr)
    history = data.get("computer_history", {})
    return history.get("policy_logs", []) or []


# ──────────────────────────────────────────────
# DATE PARSING
# ──────────────────────────────────────────────
def parse_utc(date_str: str) -> datetime | None:
    """Parse Jamf's UTC date string to a timezone-aware datetime, or None."""
    if not date_str:
        return None
    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%d %H:%M:%S",
    ):
        try:
            dt = datetime.strptime(date_str, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    log.debug("Could not parse date: %s", date_str)
    return None


# ──────────────────────────────────────────────
# MAIN SCAN LOGIC
# ──────────────────────────────────────────────
def build_policy_last_run_map(
    jamf_url: str,
    token_mgr: TokenManager,
    computer_ids: list[int],
    policy_ids: set[int],
    workers: int,
) -> dict[int, dict]:
    """
    Scans every computer's policy logs in parallel.
    Returns a dict keyed by policy_id with last-run info.
    """
    result: dict[int, dict] = {
        pid: {
            "last_run_utc": None,
            "last_run_computer_id": None,
            "last_run_status": "Never Run",
            "total_executions": 0,
        }
        for pid in policy_ids
    }

    total = len(computer_ids)
    done  = 0
    # Protect result dict writes from concurrent threads
    result_lock = threading.Lock()

    def process_computer(cid: int):
        return cid, get_policy_logs_for_computer(jamf_url, token_mgr, cid)

    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(process_computer, cid): cid for cid in computer_ids}
        for future in as_completed(futures):
            cid = futures[future]
            try:
                _, logs = future.result()
            except Exception as exc:
                log.warning("Computer %s: error fetching logs -- %s", cid, exc)
                logs = []

            with result_lock:
                for entry in logs:
                    pid = entry.get("policy_id")
                    if pid not in result:
                        continue

                    result[pid]["total_executions"] += 1

                    run_dt       = parse_utc(entry.get("date_completed_utc", ""))
                    current_best = result[pid]["last_run_utc"]

                    if run_dt and (current_best is None or run_dt > current_best):
                        result[pid]["last_run_utc"]         = run_dt
                        result[pid]["last_run_computer_id"] = cid
                        result[pid]["last_run_status"]      = entry.get("status", "")

                done += 1
                if done % 50 == 0 or done == total:
                    log.info("Progress: %d / %d computers processed...", done, total)

    return result


# ──────────────────────────────────────────────
# CSV OUTPUT
# ──────────────────────────────────────────────
def write_csv(
    policies: list[dict],
    last_run_map: dict[int, dict],
    output_path: str,
    last_run_days: int | None,
) -> int:
    """
    Write results to CSV. If last_run_days is set, only include policies
    whose last run is older than that many days (or never run).
    Returns the number of rows written.
    """
    name_map = {p["id"]: p["name"] for p in policies}
    now      = datetime.now(tz=timezone.utc)
    cutoff   = (now - timedelta(days=last_run_days)) if last_run_days else None

    rows = []
    for pid, info in last_run_map.items():
        dt = info["last_run_utc"]

        # Apply --last-run filter
        if cutoff is not None:
            if dt is not None and dt >= cutoff:
                continue  # ran recently enough — skip

        days_since = (
            (now - dt).days if dt else None
        )

        rows.append({
            "Policy ID":   pid,
            "Policy Name": name_map.get(pid, f"Unknown ({pid})"),
            "Last Run (UTC)": (
                dt.strftime("%Y-%m-%d %H:%M:%S UTC") if dt else "Never"
            ),
            "Days Since Last Run":              days_since if days_since is not None else "Never",
            "Last Run Computer ID":             info["last_run_computer_id"] or "",
            "Last Run Status":                  info["last_run_status"],
            "Total Executions (all computers)": info["total_executions"],
        })

    rows.sort(key=lambda r: (
        # Never-run policies sort to top, then oldest first
        (0 if r["Days Since Last Run"] == "Never" else 1),
        -(r["Days Since Last Run"] if isinstance(r["Days Since Last Run"], int) else 0),
        r["Policy Name"].lower(),
    ))

    fieldnames = [
        "Policy ID",
        "Policy Name",
        "Last Run (UTC)",
        "Days Since Last Run",
        "Last Run Computer ID",
        "Last Run Status",
        "Total Executions (all computers)",
    ]

    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    log.info("CSV written to: %s  (%d rows)", output_path, len(rows))
    return len(rows)


# ──────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────
def parse_args():
    parser = argparse.ArgumentParser(
        description="Report last run time for every Jamf Pro policy across all computers.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Full report — all policies
  python3 jamf_policy_last_run.py --url https://acme.jamfcloud.com \\
      --client-id abc123 --client-secret secret

  # Only policies not run in the last year (or never run)
  python3 jamf_policy_last_run.py ... --last-run 365

  # Only policies never run at all
  python3 jamf_policy_last_run.py ... --last-run 0
        """,
    )
    parser.add_argument("--url",           default=DEFAULT_JAMF_URL,
                        help="Jamf Pro URL")
    parser.add_argument("--client-id",     default=DEFAULT_JAMF_CLIENT_ID,
                        help="API client ID")
    parser.add_argument("--client-secret", default=DEFAULT_JAMF_CLIENT_SECRET,
                        help="API client secret")
    parser.add_argument("--workers",       type=int, default=MAX_WORKERS,
                        help=f"Parallel threads (default: {MAX_WORKERS})")
    parser.add_argument("--last-run",      type=int, default=None, metavar="DAYS",
                        help=(
                            "Only output policies whose last run is older than DAYS days, "
                            "or that have never been run. "
                            "Use 0 to show only policies that have never run."
                        ))
    parser.add_argument("--output",        default="",
                        help="Output CSV path (default: auto-named with timestamp)")
    return parser.parse_args()


def main():
    args = parse_args()

    jamf_url = args.url.rstrip("/")
    if not jamf_url or jamf_url == "https://yourserver.jamfcloud.com":
        sys.exit("ERROR: Set --url or the JAMF_URL environment variable.")

    client_id     = args.client_id
    client_secret = args.client_secret
    if not client_id or not client_secret:
        sys.exit(
            "ERROR: Provide --client-id and --client-secret, "
            "or set JAMF_CLIENT_ID / JAMF_CLIENT_SECRET."
        )

    # Build token manager — handles all auth and auto-refresh
    log.info("Authenticating via OAuth client_credentials...")
    token_mgr = TokenManager(jamf_url, client_id, client_secret)
    _ = token_mgr.token  # trigger initial fetch and validate creds early

    # Output path
    ts          = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_path = args.output or f"jamf_policy_last_run_{ts}.csv"

    # Fetch data
    log.info("Fetching all policies...")
    policies = get_all_policies(jamf_url, token_mgr)
    if not policies:
        sys.exit("No policies found. Check credentials and permissions.")

    policy_ids = {p["id"] for p in policies}

    log.info("Fetching all computer IDs...")
    computer_ids = get_all_computer_ids(jamf_url, token_mgr)
    if not computer_ids:
        sys.exit("No computers found.")

    filter_msg = (
        f"  Filter: policies not run in the last {args.last_run} day(s)"
        if args.last_run is not None else "  Filter: none (all policies)"
    )
    log.info(
        "Scanning policy logs across %d computers with %d worker threads...",
        len(computer_ids), args.workers,
    )
    log.info(filter_msg)

    start = time.time()
    last_run_map = build_policy_last_run_map(
        jamf_url, token_mgr, computer_ids, policy_ids, args.workers
    )
    elapsed = time.time() - start
    log.info("Scan complete in %.1f seconds.", elapsed)

    rows_written = write_csv(policies, last_run_map, output_path, args.last_run)

    # Summary
    never_run   = sum(1 for v in last_run_map.values() if v["last_run_utc"] is None)
    print(f"\n  Report : {output_path}")
    print(f"  Policies scanned        : {len(policies)}")
    print(f"  Computers scanned       : {len(computer_ids)}")
    print(f"  Policies never run      : {never_run}")
    if args.last_run is not None:
        print(f"  Rows in report (>{args.last_run}d or never): {rows_written}")
    print(f"  Elapsed                 : {elapsed:.1f}s")


if __name__ == "__main__":
    main()