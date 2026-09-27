# box-upkeep

Keeps AOS alive after a reboot or an Update on the Grok Bot / Cursor VM. It is not AOS law.

The gate is not implemented here. Nothing from [`box-access`](https://github.com/n-huche/box-access) is vendored: no gate packages, no gate watchdogs, no gate apt workarounds, no gate secrets, no copies of its units or scripts. `./up.sh` only executes that repo's orchestrator (`../box-access/up.sh`, or `BOX_ACCESS_UP`), then `./aos-up.sh`. `./bootstrap.sh` execs `./up.sh` with the same arguments.

There is no conventional systemd here. Cron and AOS stay up through vendored bash loops (`flock` + `nohup`) in this repo.

After an Update, apt packages are often gone and daemons do not come back. `/workspace` persists. Run `./up.sh` again.

## Layout

`aos-up.sh` is the AOS orchestrator. It sources `lib/common.sh`, then each `steps/*.sh` in order. Steps share one shell. Each step is idempotent.

```text
up.sh                           # gate, then aos-up.sh; honors flags
bootstrap.sh                    # exec ./up.sh "$@"; same arguments
aos-up.sh                       # AOS steps below
lib/common.sh                   # paths, config, flags
config/aos.env                  # default AOS URL, path, timezone
steps/01-timezone.sh            # America/Sao_Paulo (cron ignores CRON_TZ)
steps/02-cronie.sh              # install cronie; start crond if it is down
steps/03-clone-aos.sh           # git clone AOS when the checkout is missing
steps/04-calendar.sh            # aos up (calendar crontab + catch-up)
steps/05-watchdogs.sh           # units/cron-watchdog.sh and aos-watchdog.sh
packages.txt                    # cronie
units/cron-watchdog.sh          # restart crond/cron
units/aos-watchdog.sh           # aos up --watch-only
```

`up.sh` does not copy scripts into `/home/box`. Watchdogs run from this checkout. Logs and lock directories sit next to the unit scripts (`*.log`, `*.lock/`) and are gitignored.

## Use

```bash
cd /workspace/box-upkeep
git pull
./up.sh
```

`./bootstrap.sh` does the same thing. Prefer `./up.sh`.

Gate only, or AOS only:

```bash
./up.sh --access-only
./up.sh --aos-only
```

Packages only (the flag is forwarded to both orchestrators; each repo defines what it installs):

```bash
./up.sh --install-only
```

Full AOS path without the keep-alive loops (`crond` is still started once by the cronie step; `aos up` still installs the crontab):

```bash
./aos-up.sh --no-watchdogs
```

Skip the clone when `/workspace/aos` is already the checkout you want (or set `AOS_ROOT`):

```bash
./aos-up.sh --skip-clone
```

Flags can be combined. `./up.sh` forwards `--install-only` and `--no-watchdogs` to both orchestrators. `--skip-clone` is passed only to `aos-up.sh`. `./bootstrap.sh` forwards arguments unchanged.

`./up.sh --help` and `./aos-up.sh --help` print the flags.

## Failure policy

`./up.sh` runs the gate, then AOS. If one side fails, that failure is printed and the other side still runs. The process exits with the first non-zero status (gate, then AOS). A missing `../box-access/up.sh` is a gate failure (status 127), not a silent skip.

`--stop-on-error` changes that: a failing gate skips `aos-up.sh` and the exit status is the gate's. `--access-only` and `--aos-only` run one side on purpose. Those two flags cannot be combined.

Inside `aos-up.sh`, a step failure stops the later AOS steps. A failed `aos up` does not start the keep-alive loops. Fix the cause and run `./aos-up.sh` again.

## What one AOS run does

`--install-only` runs steps 01 and 02 and stops. `--skip-clone` still runs step 03, which returns immediately. `--no-watchdogs` skips step 05. Otherwise:

1. **`01-timezone.sh`** — Set the host localtime to `America/Sao_Paulo` (`BOX_TZ`). Debian cron and Debian cronie schedule in local time and ignore `CRON_TZ`, so AOS `0 0` is agency midnight only when the host zone is that zone.
2. **`02-cronie.sh`** — Install `cronie` from `packages.txt` if it is missing. Start `/usr/sbin/crond` (or `/usr/sbin/cron`) once when no cron daemon is running.
3. **`03-clone-aos.sh`** — If `AOS_ROOT` (default `/workspace/aos`) has no `.git`, `git clone` `AOS_REPO_URL`. A checkout that is already present is left as-is (no pull). A path that exists and is not a git clone is an error. `--skip-clone` prints `clone: skipped` and does not fetch.
4. **`04-calendar.sh`** — Run `$AOS_ROOT/scripts/aos up` (crontab + catch-up, not `--watch-only`). A missing binary, a non-zero exit, `crontab-error:`, or `crontab-unavailable` fails the step.
5. **`05-watchdogs.sh`** — Stop a previous cron/AOS watchdog from this repo (and a leftover copy under `/home/box/upkeep/` of those two scripts), then start `units/cron-watchdog.sh` and `units/aos-watchdog.sh`. Skipped with `--no-watchdogs`.

## AOS checkout

Default remote, also in `config/aos.env`:

```text
https://github.com/n-huche/aos.git
```

Override without editing the file:

```bash
AOS_REPO_URL=https://github.com/n-huche/aos.git AOS_ROOT=/workspace/aos ./aos-up.sh
```

An exported variable wins over `config/aos.env`. The clone does not prompt (`GIT_TERMINAL_PROMPT=0`). This repo does not clone private life into `aos/user`. AOS needs that tree on disk for daily close; clone it yourself if you keep one. This repo does not contain tasks, dailies, or other AOS law.

The gate entry defaults to `../box-access/up.sh`. Override with `BOX_ACCESS_UP`. `AOS_UP` overrides `./aos-up.sh` (tests and unusual layouts).

## Keep-alive

| Unit | Behavior |
|---|---|
| `units/cron-watchdog.sh` | Loop. If `crond` or `cron` is down, start it. `flock` so only one loop runs. Exponential backoff (5s–60s) when the binary is missing. |
| `units/aos-watchdog.sh` | Loop. When `$AOS_ROOT/scripts/aos` exists, run `aos up --watch-only`. Does not install the crontab (that is step 04). Waits if the binary is not there yet. Same `flock` and backoff. |

Re-run `./up.sh` after reboot or Update. The loops then keep cron and AOS watch up if either process crashes. They are not systemd units. A reboot stops the loops until `up.sh` starts them again. How you reach the box is `box-access`; this repo does not describe that path.

## Older `/home/box/upkeep` copies

Previous versions installed `/home/box/start.sh` and copied watchdogs into `/home/box/upkeep`, including copies of the gate. Those gate copies are not in this repo and are not installed anymore. Step 05 only replaces this repo's cron and aos loops (here, and a leftover cron/aos pair under `/home/box/upkeep`). It does not start or stop the gate.

## What git does not store

- Watchdog logs and lock directories
- `.env` / `.env.*`
- The AOS checkout and its private `user/` tree
- Anything the gate stores (that repo, not this one)

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`).
- Do not consume the worker pool.
- Do not implement the gate in this repo. Do not vendor its packages, watchdogs, apt workarounds, secrets, or units. `./up.sh` only executes `box-access/up.sh`.
- Does not contain AOS law (tasks, daily). Sets host localtime so AOS `0 0` is agency midnight, installs cronie, clones the AOS repo when it is missing, and keeps `aos up --watch-only` running.
- Never commit secrets.
