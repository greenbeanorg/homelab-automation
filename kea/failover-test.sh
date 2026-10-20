#!/usr/bin/env bash
# failover-test.sh — run the Kea hot-standby failover test end to end from dority.
#
#   1. preflight: both peers hot-standby, kea1 serving, ssh/sudo access works
#   2. stop kea1, time kea2's move to partner-down
#   3. make client1 re-run DHCP, confirm kea2 answered (server id = kea2)
#   4. start kea1, time the failback and any gap with nobody serving
#   5. confirm the lease kea2 issued was synced back to kea1
#
# HA state comes from status-get and leases from lease4-get over the Kea API
# (the same read-only commands kea-mcp uses), polled once per second, so
# times are accurate to about 1 s. The only privileged actions are stopping/
# starting kea-dhcp4 on kea1 and cycling DHCP on client1, each allowed by a
# narrow sudoers rule. If the script exits early for any reason, it starts
# kea1 again.
set -uo pipefail

KEA1=10.79.20.70; KEA2=10.79.20.71; API_PORT=8004
CLIENT=10.79.61.50; SSH_USER=aba
ENV_FILE=${ENV_FILE:-$HOME/git/kea-mcp/.env}
PARTNER_DOWN_TIMEOUT=${PARTNER_DOWN_TIMEOUT:-120}   # max-response-delay is 60 s; allow two
LEASE_TIMEOUT=${LEASE_TIMEOUT:-90}
FAILBACK_TIMEOUT=${FAILBACK_TIMEOUT:-120}
# Kea 3.0 lease caching is on by default (cache-threshold 0.25): a client that
# comes back before 25% of its lease lifetime has passed gets the existing lease
# back with no database write, so there is nothing new to see on kea2 or to
# sync to kea1. By default the test waits until client1's lease is past that
# threshold, so kea2 must write a fresh lease. NO_WAIT=1 skips the wait; the
# test then still proves kea2 answered (server id), but not the write or sync.
CACHE_THRESHOLD=${CACHE_THRESHOLD:-0.25}
NO_WAIT=${NO_WAIT:-0}

RESULTS_DIR="$(cd "$(dirname "$0")" && pwd)/results"
mkdir -p "$RESULTS_DIR"
OUT="$RESULTS_DIR/failover-$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "$OUT") 2>&1

# ---------- helpers ----------
now()   { date +%s.%3N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%5.1f", b-a}'; }
ts()    { date -u +%H:%M:%S.%3N; }
say()   { printf '%s  %s\n' "$(ts)" "$*"; }
die()   { say "FAIL: $*"; exit 1; }
SSH()   { ssh -o BatchMode=yes -o ConnectTimeout=5 "$@"; }

envval() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1 | sed "s/^[\"']//; s/[\"']\$//"; }
[[ -r $ENV_FILE ]] || die "cannot read $ENV_FILE (KEA_USER / KEA_PASSWORD)"
API_USER=$(envval KEA_USER); API_PW=$(envval KEA_PASSWORD)
[[ -n $API_USER && -n $API_PW ]] || die "KEA_USER or KEA_PASSWORD missing from $ENV_FILE"

# api IP COMMAND [ARGS-JSON]: credentials go to curl on stdin, never on the command line
api() {
  local body="{\"command\":\"$2\"${3:+,\"arguments\":$3}}"
  printf 'user = "%s:%s"\n' "$API_USER" "$API_PW" |
    curl -sf -K - -m 2 -H 'Content-Type: application/json' -d "$body" "http://$1:$API_PORT/"
}

# ha IP -> "state scope,scope" or "unreachable"
ha() {
  local r
  r=$(api "$1" status-get) || { echo unreachable; return; }
  jq -r '.[0].arguments["high-availability"][0]["ha-servers"].local
         | "\(.state) \(.scopes | join(","))"' <<<"$r" 2>/dev/null || echo unreachable
}

# cltt IP -> client last transmission time of CLIENT's lease on that server
lease() { api "$1" lease4-get "{\"ip-address\":\"$CLIENT\"}"; }
cltt()  { lease "$1" | jq -r '.[0].arguments.cltt // empty'; }
vlft()  { lease "$1" | jq -r '.[0].arguments["valid-lft"] // empty'; }

client_server_id() {
  SSH "$SSH_USER@$CLIENT" "nmcli -f DHCP4 dev show | sed -n 's/.*dhcp_server_identifier = //p' | head -n1" 2>/dev/null
}

KEA1_STOPPED=0
cleanup() {
  if (( KEA1_STOPPED )); then
    say "cleanup: starting kea-dhcp4 on kea1"
    SSH "$SSH_USER@$KEA1" 'sudo -n /usr/bin/systemctl start kea-dhcp4' || say "cleanup FAILED: start kea1 by hand"
  fi
  say "results saved to $OUT"
}
trap cleanup EXIT
trap 'say "interrupted"; exit 130' INT TERM

# ---------- 1. preflight ----------
say "== preflight"
s1=$(ha $KEA1); s2=$(ha $KEA2)
say "kea1: $s1"; say "kea2: $s2"
[[ $s1 == "hot-standby kea1" ]] || die "kea1 is not hot-standby serving kea1"
[[ $s2 == "hot-standby " ]]     || die "kea2 is not hot-standby with no scopes"

SSH "$SSH_USER@$KEA1" 'sudo -n -l /usr/bin/systemctl stop kea-dhcp4 && sudo -n -l /usr/bin/systemctl start kea-dhcp4' >/dev/null \
  || die "kea1: no passwordless sudo for systemctl stop/start kea-dhcp4 (see failover-test README section)"
SSH "$SSH_USER@$CLIENT" 'sudo -n -l /usr/local/sbin/dhcp-cycle' >/dev/null \
  || die "client1: cannot ssh in, or no passwordless sudo for /usr/local/sbin/dhcp-cycle"

sid0=$(client_server_id)
say "client1 server id: ${sid0:-unknown}"
[[ $sid0 == "$KEA1" ]] || say "note: client1's current lease is not from kea1"

# Lease age vs the cache threshold (the clock that matters is Kea's: use kea1's
# view of the lease, which is the authoritative copy before the test).
c_pre=$(cltt $KEA1); lft=$(vlft $KEA1)
[[ -n $c_pre && -n $lft ]] || die "no lease for $CLIENT on kea1"
thresh=$(awk -v l="$lft" -v t="$CACHE_THRESHOLD" 'BEGIN{printf "%d", l*t}')
need=$(( thresh + 90 ))    # margin: ~60 s failover + client cycle before kea2 sees the request
age=$(( $(date +%s) - c_pre ))
say "client1 lease age ${age}s, lifetime ${lft}s, cache threshold ${thresh}s"
if (( age < need )); then
  if (( NO_WAIT )); then
    say "NO_WAIT=1: kea2 will likely reuse the cached lease; write and sync checks will be n/a"
  else
    wait_s=$(( need - age ))
    say "waiting ${wait_s}s so the lease is past the cache threshold and kea2 must write a new one"
    say "(Ctrl+C is safe: nothing has been changed yet)"
    sleep "$wait_s"
    c_now=$(cltt $KEA1)
    if [[ $c_now != "$c_pre" ]]; then
      die "client1 renewed with kea1 while we waited (cltt changed); run the test again"
    fi
  fi
fi
c2_before=$(cltt $KEA2)
say "kea2 lease cltt before failover: ${c2_before:-none}"

# ---------- 2. stop kea1 ----------
say "== failover"
T0=$(now)
SSH "$SSH_USER@$KEA1" 'sudo -n /usr/bin/systemctl stop kea-dhcp4' || die "could not stop kea1"
KEA1_STOPPED=1
say "kea1 stopped (t=0)"

last=""
while :; do
  s2=$(ha $KEA2)
  [[ $s2 != "$last" ]] && { say "t=$(since "$T0")s  kea2: $s2"; last=$s2; }
  [[ $s2 == partner-down* ]] && break
  awk -v e="$(since "$T0")" -v t=$PARTNER_DOWN_TIMEOUT 'BEGIN{exit !(e>t)}' && die "kea2 did not reach partner-down in ${PARTNER_DOWN_TIMEOUT}s"
  sleep 1
done
FAILOVER=$(since "$T0")
say "kea2 in partner-down after ${FAILOVER}s"

# ---------- 3. client1 gets a lease from kea2 ----------
say "== client lease during failover"
T1=$(now)
SSH "$SSH_USER@$CLIENT" 'sudo -n /usr/local/sbin/dhcp-cycle' || die "dhcp-cycle on client1 failed"
sleep 5    # client1's address goes away for a moment; ssh is down until it's back
sid=""
while :; do
  sid=$(client_server_id)
  [[ $sid == "$KEA2" ]] && break
  awk -v e="$(since "$T1")" -v t=$LEASE_TIMEOUT 'BEGIN{exit !(e>t)}' && die "client1 did not get a lease from kea2 (server id: ${sid:-none})"
  sleep 2
done
LEASE_T=$(since "$T1")
c2_during=$(cltt $KEA2)
say "client1 leased $CLIENT from server id $sid after ${LEASE_T}s; kea2 cltt: $c2_during"
if [[ -n $c2_during && $c2_during != "$c2_before" ]]; then
  NEWLEASE=1; WROTE="yes, kea2 wrote a new lease (cltt $c2_during)"
else
  NEWLEASE=0; WROTE="no, kea2 reused the cached lease (no database write)"
fi
say "kea2 wrote a new lease: $WROTE"

# ---------- 4. failback ----------
say "== failback"
T2=$(now)
SSH "$SSH_USER@$KEA1" 'sudo -n /usr/bin/systemctl start kea-dhcp4' || die "could not start kea1"
KEA1_STOPPED=0
say "kea1 started (t=0)"

last=""; gap_start=""; GAP=0
while :; do
  s1=$(ha $KEA1); s2=$(ha $KEA2); cur="kea1: $s1 | kea2: $s2"
  [[ $cur != "$last" ]] && { say "t=$(since "$T2")s  $cur"; last=$cur; }
  # nobody serving: no reachable peer lists a scope
  if [[ ${s1#* } == "" || $s1 == unreachable ]] && [[ ${s2#* } == "" || $s2 == unreachable ]]; then
    [[ -z $gap_start ]] && gap_start=$(now)
  elif [[ -n $gap_start ]]; then
    GAP=$(since "$gap_start"); gap_start=""
  fi
  [[ $s1 == "hot-standby kea1" && $s2 == "hot-standby " ]] && break
  awk -v e="$(since "$T2")" -v t=$FAILBACK_TIMEOUT 'BEGIN{exit !(e>t)}' && die "pair did not return to normal in ${FAILBACK_TIMEOUT}s"
  sleep 1
done
FAILBACK=$(since "$T2")
say "pair back to normal after ${FAILBACK}s (nobody-serving gap during handback: ${GAP}s)"

# ---------- 5. lease synced back ----------
c1_after=$(cltt $KEA1)
say "kea1 cltt: ${c1_after:-none}  kea2 cltt: $c2_during"
if (( NEWLEASE )); then
  [[ $c1_after == "$c2_during" ]] && SYNC=PASS || SYNC=FAIL
else
  SYNC="n/a (no new lease to sync; peers agree: $([[ $c1_after == "$c2_during" ]] && echo yes || echo NO))"
fi

# ---------- summary ----------
cat <<SUM

==================== RESULT ====================
failover  (stop kea1 -> kea2 partner-down)   ${FAILOVER} s
client    (dhcp cycle -> lease from kea2)    ${LEASE_T} s   server id $sid
kea2 wrote a new lease                       $WROTE
failback  (start kea1 -> both hot-standby)   ${FAILBACK} s
handback gap with nobody serving             ${GAP} s
lease issued by kea2 synced to kea1          ${SYNC}
(times from 1 s polling of status-get)
================================================
SUM
[[ $SYNC == PASS || $SYNC == n/a* ]]
