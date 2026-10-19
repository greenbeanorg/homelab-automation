#!/usr/bin/env bash
# Usage: ./deploy.sh kea1|kea2
# Renders the repo config with the Postgres password from .secrets/ (untracked),
# installs it on the host as kea-dhcp4.conf.candidate with the live file's owner
# and mode, and runs kea-dhcp4 -t on it. It does NOT restart Kea:
# activation is a deliberate, separate step because peer order matters.
# Note: kea-dhcp4 -t checks syntax and core config but does not load hooks,
# so HA parameter errors only show at the real start. Watch the log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
  kea1) addr=10.79.20.70 ;;
  kea2) addr=10.79.20.71 ;;
  *) echo "usage: $0 kea1|kea2" >&2; exit 2 ;;
esac
host=$1
"$here/check-peer-diff.sh"
secret="$here/.secrets/pg-password"
[[ -r $secret ]] || { echo "missing $secret (one line: the Postgres password for user kea)" >&2; exit 1; }
umask 077
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
jq --rawfile pw "$secret" '.Dhcp4["lease-database"].password = ($pw | rtrimstr("\n"))' \
  "$here/$host/kea-dhcp4.conf" > "$tmp"
scp -q "$tmp" "aba@$addr:kea-dhcp4.conf.new"
ssh -t "aba@$addr" '
  set -e
  live=/etc/kea/kea-dhcp4.conf; cand=/etc/kea/kea-dhcp4.conf.candidate
  sudo cp ~/kea-dhcp4.conf.new "$cand"; rm -f ~/kea-dhcp4.conf.new
  sudo chown --reference="$live" "$cand"; sudo chmod --reference="$live" "$cand"
  sudo restorecon "$cand" 2>/dev/null || true
  sudo kea-dhcp4 -t "$cand"
  echo
  echo "VALID: $cand"
  echo "Activate with:"
  echo "  sudo cp -a $live $live.prev && sudo mv $cand $live && sudo systemctl restart kea-dhcp4"
'
