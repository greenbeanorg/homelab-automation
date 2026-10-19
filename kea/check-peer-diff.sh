#!/usr/bin/env bash
# Fails unless kea1 and kea2 configs differ ONLY in this-server-name,
# and each names itself correctly. Run before every deploy.
set -euo pipefail
cd "$(dirname "$0")"
norm='walk(if type == "object" then del(.["this-server-name"]) else . end)'
for h in kea1 kea2; do
  jq -e . "$h/kea-dhcp4.conf" >/dev/null || { echo "FAIL: $h/kea-dhcp4.conf is not valid JSON" >&2; exit 1; }
  name=$(jq -r '.Dhcp4["hooks-libraries"][] | select(.library|test("libdhcp_ha")) | .parameters["high-availability"][0]["this-server-name"]' "$h/kea-dhcp4.conf")
  [[ $name == "$h" ]] || { echo "FAIL: $h/kea-dhcp4.conf has this-server-name '$name'" >&2; exit 1; }
done
if diff -u <(jq -S "$norm" kea1/kea-dhcp4.conf) <(jq -S "$norm" kea2/kea-dhcp4.conf); then
  echo "OK: kea1 and kea2 differ only in this-server-name"
else
  echo "FAIL: peer configs have drifted (diff above)" >&2; exit 1
fi
