#!/usr/bin/env python3
"""
kuma_repave.py — declarative Uptime Kuma sync.

Unlike kuma_sync.py (incremental: CREATE/UPDATE/OK, never deletes UNMANAGED),
this script treats inventory.yaml as the ENTIRE truth. Every run:

    1. Logs into Kuma.
    2. Reports every monitor that currently exists (with notification/tag
       bindings flagged), plus known maintenance windows and status pages
       that reference monitor IDs — all of this is lost on delete.
    3. On --apply --yes-i-mean-it: deletes every existing monitor, then
       creates one monitor per inventory.yaml entry, in that order.

WARNING — deleting a monitor in Kuma also deletes its heartbeat/uptime
history, and any notifications, tags, maintenance-window membership, or
status-page membership tied to it. Recreated monitors start clean; you
will need to reattach those by hand (or via inventory.yaml if you extend
the schema to carry notificationIDList / tags). This is fundamentally
more destructive than pihole_repave.py, which only ever touches DNS
records with no history to lose.

USAGE
    uv run kuma_repave.py                            # dry run (default)
    uv run kuma_repave.py --apply --yes-i-mean-it     # wipe + repave
    uv run kuma_repave.py --inventory path/to/inventory.yaml

AUTH — same as kuma_sync.py: KUMA_URL / KUMA_USERNAME / KUMA_PASSWORD in
.env (python-dotenv), plus any ${VAR} referenced in inventory.yaml headers.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

import yaml
from dotenv import load_dotenv
from uptime_kuma_api import MonitorType, UptimeKumaApi


load_dotenv()

KUMA_URL = os.getenv("KUMA_URL", "http://localhost:3001")
KUMA_USERNAME = os.getenv("KUMA_USERNAME")
KUMA_PASSWORD = os.getenv("KUMA_PASSWORD")
DEFAULT_INVENTORY = "inventory.yaml"

SOCKET_SETTLE_DELAY = 2
KUMA_TIMEOUT = 30

TYPE_MAP = {
    "ping": MonitorType.PING,
    "http": MonitorType.HTTP,
    "json-query": MonitorType.JSON_QUERY,
}


# ---------------------------------------------------------------------------
# inventory.yaml -> desired monitor list (identical logic to kuma_sync.py)
# ---------------------------------------------------------------------------

def load_inventory(path):
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def expand_env(value):
    """Expand ${ENV_VAR} references in strings."""
    if value is None:
        return None
    return os.path.expandvars(value)


def build_desired_monitors(inventory):
    desired = []

    for site, categories in inventory.items():
        for category, monitors in categories.items():
            for monitor in monitors:

                monitor_type = monitor["type"].lower()
                if monitor_type not in TYPE_MAP:
                    raise ValueError(
                        f"Unsupported monitor type '{monitor_type}' "
                        f"for {monitor['name']}"
                    )

                headers = expand_env(monitor.get("headers"))
                accepted_statuscodes = monitor.get(
                    "accepted_statuscodes", ["200-299"]
                )

                desired.append(
                    {
                        "site": site,
                        "category": category,
                        "name": monitor["name"],
                        "type": TYPE_MAP[monitor_type],
                        "type_name": monitor_type,
                        "target": monitor["target"],
                        "headers": headers,
                        "accepted_statuscodes": accepted_statuscodes,
                        "jsonPath": monitor.get("jsonPath"),
                        "jsonPathOperator": monitor.get(
                            "jsonPathOperator", "=="
                        ),
                        "expectedValue": monitor.get("expectedValue"),
                    }
                )

    return desired


# ---------------------------------------------------------------------------
# Kuma connection
# ---------------------------------------------------------------------------

def connect():
    if not KUMA_USERNAME:
        print("ERROR: KUMA_USERNAME is not set in .env")
        sys.exit(1)
    if not KUMA_PASSWORD:
        print("ERROR: KUMA_PASSWORD is not set in .env")
        sys.exit(1)

    print(f"Connecting to Kuma at {KUMA_URL}...")
    api = UptimeKumaApi(KUMA_URL, timeout=KUMA_TIMEOUT)

    print(f"Waiting {SOCKET_SETTLE_DELAY}s for Socket.IO initialization...")
    time.sleep(SOCKET_SETTLE_DELAY)

    api.login(KUMA_USERNAME, KUMA_PASSWORD)
    print("Authenticated.\n")
    return api


# ---------------------------------------------------------------------------
# Pre-delete report — this is the "orphan report" equivalent from
# pihole_repave.py, but for Kuma the stakes are higher: history, tags,
# notifications, maintenance windows, and status pages are all at risk.
# Printed every run, including dry-run, since it's the only warning
# before an unrecoverable wipe.
# ---------------------------------------------------------------------------

def print_pre_delete_report(api, existing_monitors):
    print("PRE-DELETE REPORT")
    print("=================")
    print(f"{len(existing_monitors)} monitor(s) currently in Kuma. "
          f"ALL will be deleted on --apply, regardless of whether "
          f"they're in inventory.yaml.\n")

    if not existing_monitors:
        print("  (nothing to delete)\n")
        return

    with_notifications = []
    with_tags = []

    for m in existing_monitors:
        notif_ids = m.get("notificationIDList")
        # library normalizes this to a list of ints in newer versions,
        # a dict of {id: bool} in older ones -- handle both defensively
        if isinstance(notif_ids, dict):
            has_notif = any(notif_ids.values())
        else:
            has_notif = bool(notif_ids)

        if has_notif:
            with_notifications.append(m["name"])

        if m.get("tags"):
            with_tags.append(m["name"])

    for m in existing_monitors:
        flags = []
        if m["name"] in with_notifications:
            flags.append("notifications")
        if m["name"] in with_tags:
            flags.append("tags")
        flag_str = f"  [{', '.join(flags)}]" if flags else ""
        print(f"  DELETE  {m['name']} (id={m['id']}){flag_str}")

    print()

    if with_notifications:
        print(f"  ! {len(with_notifications)} monitor(s) have notifications "
              f"attached -- these bindings do NOT survive delete/recreate. "
              f"Reattach manually in the UI after repave, or extend "
              f"inventory.yaml to carry notificationIDList and this script "
              f"to reapply it.")
    if with_tags:
        print(f"  ! {len(with_tags)} monitor(s) have tags attached -- tags "
              f"do NOT survive delete/recreate either.")

    try:
        maintenances = api.get_maintenances()
    except Exception as e:
        maintenances = None
        print(f"  ? Could not check maintenance windows ({e}). "
              f"Check manually -- maintenance windows reference monitor "
              f"IDs, and deleted/recreated monitors get new IDs, silently "
              f"dropping out of any window they were in.")

    if maintenances:
        print(f"  ! {len(maintenances)} maintenance window(s) exist. Any "
              f"scoped to specific monitors (not 'all monitors') will "
              f"silently stop covering those monitors once they're "
              f"recreated with new IDs -- re-check maintenance windows "
              f"after repave.")

    try:
        status_pages = api.get_status_pages()
    except Exception:
        status_pages = None

    if status_pages:
        print(f"  ! {len(status_pages)} status page(s) exist. They "
              f"reference monitors by ID too -- re-check their monitor "
              f"lists after repave.")

    print(f"\n  ! Heartbeat/uptime history for all {len(existing_monitors)} "
          f"monitor(s) above is deleted permanently, no exceptions -- "
          f"recreated monitors start at 0% history.\n")


# ---------------------------------------------------------------------------
# Repave
# ---------------------------------------------------------------------------

def create_monitor(api, desired, dry_run):
    print(f"  CREATE  {desired['name']}")
    print(f"          site:     {desired['site']}")
    print(f"          category: {desired['category']}")
    print(f"          type:     {desired['type_name']}")
    print(f"          target:   {desired['target']}")

    if desired["headers"] is not None:
        print("          headers:  [configured]")

    if desired["type"] in (MonitorType.HTTP, MonitorType.JSON_QUERY):
        print(f"          status:   {desired['accepted_statuscodes']}")

    if desired["type"] == MonitorType.JSON_QUERY:
        print(f"          jsonPath: {desired['jsonPath']}")
        print(f"          operator: {desired['jsonPathOperator']}")
        print(f"          expected: {desired['expectedValue']}")

    if dry_run:
        return

    kwargs = {"type": desired["type"], "name": desired["name"]}

    if desired["type"] == MonitorType.PING:
        kwargs["hostname"] = desired["target"]
    elif desired["type"] in (MonitorType.HTTP, MonitorType.JSON_QUERY):
        kwargs["url"] = desired["target"]
        kwargs["accepted_statuscodes"] = desired["accepted_statuscodes"]
        if desired["headers"] is not None:
            kwargs["headers"] = desired["headers"]

    if desired["type"] == MonitorType.JSON_QUERY:
        kwargs["jsonPath"] = desired["jsonPath"]
        kwargs["jsonPathOperator"] = desired["jsonPathOperator"]
        kwargs["expectedValue"] = desired["expectedValue"]

    api.add_monitor(**kwargs)


def repave(api, desired, apply, really):
    existing_monitors = api.get_monitors()

    print_pre_delete_report(api, existing_monitors)

    print("DESIRED (from inventory.yaml)")
    print("==============================")
    for monitor in desired:
        create_monitor(api, monitor, dry_run=True)
    print()

    if not apply:
        print("(dry run — nothing changed; re-run with "
              "--apply --yes-i-mean-it)")
        return

    if not really:
        print("! --apply given without --yes-i-mean-it — refusing to touch "
              "anything. Add --yes-i-mean-it once you've reviewed the "
              "report above.")
        return

    print("DELETING existing monitors...")
    for m in existing_monitors:
        api.delete_monitor(m["id"])
        print(f"  deleted  {m['name']} (id={m['id']})")

    print("\nCREATING monitors from inventory.yaml...")
    for monitor in desired:
        create_monitor(api, monitor, dry_run=False)

    print(f"\nDone: deleted {len(existing_monitors)}, "
          f"created {len(desired)}.")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Wipe and rebuild Uptime Kuma monitors from inventory.yaml "
            "(declarative — inventory.yaml is the ENTIRE truth)"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--inventory", default=DEFAULT_INVENTORY)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform the wipe + repave (default: dry run)",
    )
    parser.add_argument(
        "--yes-i-mean-it",
        action="store_true",
        dest="really",
        help="required alongside --apply to actually delete anything",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    try:
        inventory = load_inventory(args.inventory)
        desired = build_desired_monitors(inventory)
        print(f"Loaded {len(desired)} desired monitor(s) from "
              f"{args.inventory}\n")

        if not args.apply:
            print("*** DRY RUN — pass --apply --yes-i-mean-it to actually "
                  "wipe + repave ***\n")

        api = connect()
        try:
            repave(api, desired, args.apply, args.really)
        finally:
            api.disconnect()

    except Exception as e:
        print(f"\nERROR: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
