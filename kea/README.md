# Kea DHCPv4 — hot-standby HA pair

| Peer | Host | Address | Role |
|---|---|---|---|
| kea1 | VM 950 on swearengen | 10.79.20.70 | primary |
| kea2 | VM 952 on garrett | 10.79.20.71 | standby |

Kea 3.0.4 LTS (ISC RPMs) on Rocky Linux 9. Each peer has its own local
PostgreSQL lease database; the HA hook keeps them in sync. No shared lease DB,
no Control Agent.

## Files

- `kea1/kea-dhcp4.conf`, `kea2/kea-dhcp4.conf` — identical except
  `this-server-name`. The Postgres password is `SET-AT-DEPLOY`; the real value is
  never committed.
- `check-peer-diff.sh` — fails unless `this-server-name` is the only difference
  and each file names its own host.
- `deploy.sh kea1|kea2` — runs the check, fills in the password from
  `.secrets/pg-password`, installs the result as `kea-dhcp4.conf.candidate` on
  the host and runs `kea-dhcp4 -t` on it. Does not restart Kea. `-t` loads the
  hook libraries but doesn't run HA configuration or connect to Postgres, so
  HA parameter and database password errors only appear at the real start.

## Ports

| Port | Listener | Allowed from (firewalld zone) |
|---|---|---|
| 67/udp | DHCP | relay + subscriber prefixes (`dhcp-relay`) |
| 8004/tcp | API, basic auth `mcp-ro` | dority only (`kea-mgmt`) |
| 8005/tcp | HA dedicated listener, HA commands only | the other peer only (`kea-peer`) |

The 8004 socket binds `0.0.0.0` so both peers can run one identical config;
firewalld is what scopes it.

## Secrets (never in Git)

- `.secrets/pg-password` on dority — Postgres password for user `kea`
- `/etc/kea/kea-ha.pw` on both peers — HA peer basic-auth password, identical on both
- `/etc/kea/kea-api-mcp.pw` on both peers — API password for `mcp-ro`
