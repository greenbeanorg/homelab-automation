#!/usr/bin/env python3

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
INVENTORY_FILE = "inventory.yaml"

SOCKET_SETTLE_DELAY = 2
KUMA_TIMEOUT = 30


TYPE_MAP = {
    "ping": MonitorType.PING,
    "http": MonitorType.HTTP,
    "json-query": MonitorType.JSON_QUERY,
}


def load_inventory():
    with open(INVENTORY_FILE, "r", encoding="utf-8") as f:
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
                        f"Unsupported monitor type "
                        f"'{monitor_type}' for "
                        f"{monitor['name']}"
                    )

                headers = expand_env(
                    monitor.get("headers")
                )

                accepted_statuscodes = monitor.get(
                    "accepted_statuscodes",
                    ["200-299"],
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
                        "accepted_statuscodes": (
                            accepted_statuscodes
                        ),
                        "jsonPath": monitor.get(
                            "jsonPath"
                        ),
                        "jsonPathOperator": monitor.get(
                            "jsonPathOperator",
                            "==",
                        ),
                        "expectedValue": monitor.get(
                            "expectedValue"
                        ),
                    }
                )

    return desired


def connect():
    if not KUMA_USERNAME:
        print(
            "ERROR: KUMA_USERNAME is not set in .env"
        )
        sys.exit(1)

    if not KUMA_PASSWORD:
        print(
            "ERROR: KUMA_PASSWORD is not set in .env"
        )
        sys.exit(1)

    print(
        f"Connecting to Kuma at {KUMA_URL}..."
    )

    api = UptimeKumaApi(
        KUMA_URL,
        timeout=KUMA_TIMEOUT,
    )

    print(
        f"Waiting {SOCKET_SETTLE_DELAY}s "
        "for Socket.IO initialization..."
    )

    time.sleep(SOCKET_SETTLE_DELAY)

    api.login(
        KUMA_USERNAME,
        KUMA_PASSWORD,
    )

    print("Authenticated.\n")

    return api


def get_existing_monitors(api):
    monitors = api.get_monitors()

    return {
        monitor["name"]: monitor
        for monitor in monitors
    }


def create_monitor(api, desired, dry_run):

    print(
        f"  CREATE  {desired['name']}"
    )

    print(
        f"          site:     "
        f"{desired['site']}"
    )

    print(
        f"          category: "
        f"{desired['category']}"
    )

    print(
        f"          type:     "
        f"{desired['type_name']}"
    )

    print(
        f"          target:   "
        f"{desired['target']}"
    )

    if desired["headers"] is not None:
        print(
            "          headers:  "
            "[configured]"
        )

    if desired["type"] in (
        MonitorType.HTTP,
        MonitorType.JSON_QUERY,
    ):
        print(
            f"          status:   "
            f"{desired['accepted_statuscodes']}"
        )

    if desired["type"] == MonitorType.JSON_QUERY:

        print(
            f"          jsonPath: "
            f"{desired['jsonPath']}"
        )

        print(
            f"          operator: "
            f"{desired['jsonPathOperator']}"
        )

        print(
            f"          expected: "
            f"{desired['expectedValue']}"
        )

    if dry_run:
        return

    kwargs = {
        "type": desired["type"],
        "name": desired["name"],
    }

    if desired["type"] == MonitorType.PING:

        kwargs["hostname"] = desired["target"]

    elif desired["type"] in (
        MonitorType.HTTP,
        MonitorType.JSON_QUERY,
    ):

        kwargs["url"] = desired["target"]

        kwargs["accepted_statuscodes"] = (
            desired["accepted_statuscodes"]
        )

        if desired["headers"] is not None:
            kwargs["headers"] = desired["headers"]

    if desired["type"] == MonitorType.JSON_QUERY:

        kwargs["jsonPath"] = (
            desired["jsonPath"]
        )

        kwargs["jsonPathOperator"] = (
            desired["jsonPathOperator"]
        )

        kwargs["expectedValue"] = (
            desired["expectedValue"]
        )

    api.add_monitor(**kwargs)


def update_monitor(
    api,
    existing,
    desired,
    dry_run,
):

    expected_type = desired["type"]

    current_type = existing.get("type")

    if expected_type == MonitorType.PING:
        current_target = existing.get(
            "hostname"
        )
    else:
        current_target = existing.get(
            "url"
        )

    expected_target = desired["target"]

    changes = []

    if current_type != expected_type.value:

        changes.append(
            f"type: {current_type} -> "
            f"{expected_type.value}"
        )

    if current_target != expected_target:

        changes.append(
            f"target: {current_target} -> "
            f"{expected_target}"
        )

    if expected_type in (
        MonitorType.HTTP,
        MonitorType.JSON_QUERY,
    ):

        current_headers = existing.get(
            "headers"
        )

        expected_headers = (
            desired["headers"]
        )

        if current_headers != expected_headers:

            changes.append(
                "headers: "
                "[changed]"
            )

        current_statuscodes = (
            existing.get(
                "accepted_statuscodes"
            )
        )

        expected_statuscodes = (
            desired[
                "accepted_statuscodes"
            ]
        )

        if (
            current_statuscodes
            != expected_statuscodes
        ):

            changes.append(
                "accepted_statuscodes: "
                f"{current_statuscodes} -> "
                f"{expected_statuscodes}"
            )

    if expected_type == MonitorType.JSON_QUERY:

        current_json_path = existing.get(
            "jsonPath"
        )

        current_operator = existing.get(
            "jsonPathOperator"
        )

        current_expected_value = (
            existing.get(
                "expectedValue"
            )
        )

        if (
            current_json_path
            != desired["jsonPath"]
        ):

            changes.append(
                f"jsonPath: "
                f"{current_json_path} -> "
                f"{desired['jsonPath']}"
            )

        if (
            current_operator
            != desired[
                "jsonPathOperator"
            ]
        ):

            changes.append(
                "jsonPathOperator: "
                f"{current_operator} -> "
                f"{desired['jsonPathOperator']}"
            )

        if (
            current_expected_value
            != desired[
                "expectedValue"
            ]
        ):

            changes.append(
                "expectedValue: "
                f"{current_expected_value} -> "
                f"{desired['expectedValue']}"
            )

    if not changes:

        print(
            f"  OK      "
            f"{desired['name']}"
        )

        return

    print(
        f"  UPDATE  "
        f"{desired['name']}"
    )

    for change in changes:
        print(
            f"          {change}"
        )

    if dry_run:
        return

    kwargs = {
        "type": expected_type,
        "name": desired["name"],
    }

    if expected_type == MonitorType.PING:

        kwargs["hostname"] = expected_target

    elif expected_type in (
        MonitorType.HTTP,
        MonitorType.JSON_QUERY,
    ):

        kwargs["url"] = expected_target

        kwargs["accepted_statuscodes"] = (
            desired[
                "accepted_statuscodes"
            ]
        )

        if desired["headers"] is not None:
            kwargs["headers"] = (
                desired["headers"]
            )

    if expected_type == MonitorType.JSON_QUERY:

        kwargs["jsonPath"] = (
            desired["jsonPath"]
        )

        kwargs["jsonPathOperator"] = (
            desired[
                "jsonPathOperator"
            ]
        )

        kwargs["expectedValue"] = (
            desired["expectedValue"]
        )

    api.edit_monitor(
        existing["id"],
        **kwargs,
    )


def sync(
    api,
    desired,
    dry_run,
):

    existing = get_existing_monitors(
        api
    )

    print(
        f"Existing Kuma monitors: "
        f"{len(existing)}"
    )

    print(
        f"Desired inventory monitors: "
        f"{len(desired)}"
    )

    print()

    desired_names = set()

    for monitor in desired:

        name = monitor["name"]

        desired_names.add(name)

        if name not in existing:

            create_monitor(
                api,
                monitor,
                dry_run,
            )

        else:

            update_monitor(
                api,
                existing[name],
                monitor,
                dry_run,
            )

    unmanaged = (
        set(existing)
        - desired_names
    )

    if unmanaged:

        print()
        print(
            "UNMANAGED MONITORS"
        )
        print(
            "------------------"
        )

        for name in sorted(
            unmanaged
        ):

            print(
                f"  {name}"
            )

        print()

        print(
            "NOTE: "
            "Unmanaged monitors are NOT deleted."
        )


def parse_args():

    parser = argparse.ArgumentParser(
        description=(
            "Synchronize inventory.yaml "
            "with Uptime Kuma"
        )
    )

    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Show what would change "
            "without modifying Kuma"
        ),
    )

    return parser.parse_args()


def main():

    args = parse_args()

    try:

        inventory = load_inventory()

        desired = build_desired_monitors(
            inventory
        )

        api = connect()

        try:

            sync(
                api,
                desired,
                args.dry_run,
            )

        finally:

            api.disconnect()

        if args.dry_run:

            print()
            print(
                "DRY RUN COMPLETE - "
                "nothing was changed."
            )

        else:

            print()
            print(
                "SYNC COMPLETE."
            )

    except Exception as e:

        print(
            f"\nERROR: {e}",
            file=sys.stderr,
        )

        sys.exit(1)


if __name__ == "__main__":
    main()

