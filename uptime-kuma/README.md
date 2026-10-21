# uptime-kuma — monitors from a YAML inventory

Every Uptime Kuma monitor in the lab is defined in one file, `inventory.yaml`,
and applied by script instead of clicked in one at a time. Adding a host is one
YAML entry, reviewed in Git like any other change.

| Script | What it does | Can it delete? |
|---|---|---|
| `kuma_sync.py` | Reconciles Kuma with the inventory: creates missing monitors, updates drifted ones, reports the rest | No. Monitors not in the inventory are listed as `UNMANAGED` and left alone |
| `kuma_repave.py` | Wipes Kuma and rebuilds every monitor from the inventory | Yes, everything. Dry run by default; deleting needs `--apply --yes-i-mean-it` |

`compose.yaml` is the Uptime Kuma 2 container these scripts talk to.

## Quick start

```bash
cp inventory.example.yaml inventory.yaml   # then describe your own hosts
cp env.example .env                        # then fill in credentials
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

python kuma_sync.py --dry-run              # read the plan first
python kuma_sync.py                        # apply it
```

`inventory.yaml` and `.env` are gitignored. `inventory.example.yaml` documents
the format with RFC 5737 addresses.

## Inventory format

```yaml
home:                      # site     — groups output only
  media:                   # category — groups output only
    - name: Plex           # monitor name, and the key the sync matches on
      type: http           # ping | http | json-query
      target: http://192.0.2.50:32400
      headers: '{"X-Plex-Token": "${PLEX_TOKEN}"}'   # ${VAR} expanded from .env
      accepted_statuscodes: ["200"]                   # default 200-299
```

- `json-query` entries add `jsonPath`, `jsonPathOperator` (default `==`) and
  `expectedValue`.
- Secrets never go in the inventory. Reference them as `${VAR}`.
- Any other type stops the run before anything is changed.

## How the sync decides

`kuma_sync.py` matches monitors by name. Then, for each inventory entry:

- **CREATE** if no monitor has that name;
- **UPDATE** if the type, target, headers, accepted status codes or JSON check
  differ;
- **OK** if nothing differs.

Monitors that exist in Kuma but not in the inventory are reported as
`UNMANAGED` and never deleted. Either add them to the inventory or delete them
in the UI.

## Safety model

- **`kuma_sync.py` never deletes**, and `--dry-run` prints the full plan without
  changing anything.
- **`kuma_repave.py` is for starting over**, and it says what starting over will
  cost before doing it. Every run, including a dry run, prints a pre-delete
  report. The report flags monitors with notifications or tags attached,
  maintenance windows and status pages. Those all reference monitors by ID, and
  a rebuild issues new IDs. Uptime history is lost permanently. `--apply` alone
  does nothing; it also needs `--yes-i-mean-it`.

## What isn't managed

- Check interval, retries and notification channels are set in the Kuma UI.
  `kuma_sync.py` doesn't touch them. `kuma_repave.py` drops them, and the
  pre-delete report says so.
- Push-type monitors (a script reporting in to Kuma) aren't in the supported
  types. They show as `UNMANAGED` and are kept out of the inventory.
- Renaming an entry creates a new monitor, because the name is the key.

## How it was built

These scripts were written with an AI coding assistant (Claude). The
specification, design decisions and safety requirements were mine: a sync that
never deletes, a repave behind two flags, and a report of everything a repave
would destroy.

Both scripts were dry-run against the live Kuma instance before they were
allowed to write. The first repave dry run showed what it would have cost: 12
monitors with notification bindings and 2 maintenance windows would have lost
their links. It also showed three VPN monitors that existed in Kuma but not in
the inventory, which a repave would have silently removed.

Entering 20-odd monitors by hand takes an hour or two of clicking, and it has
to be redone every time addresses change. With the inventory, a whole-lab
renumbering is a reviewed edit and a sync run.
