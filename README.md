# box-upkeep

Keeps AOS alive after a reboot or an Update on the Grok Bot / Cursor VM. It is not AOS law.

The gate is not implemented here. Nothing from [`box-access`](https://github.com/n-huche/box-access) is vendored: no gate packages, no gate watchdogs, no gate apt workarounds, no gate secrets, no copies of its units or scripts. `./up.sh` executes that repo's orchestrator (`../box-access/up.sh`, or `BOX_ACCESS_UP`), then the AOS entry (`./aos/aos-up.sh`, or `AOS_UP`). `./aos-up.sh` at the repo root execs `./aos/aos-up.sh`. When `java` or `javac` does not run, `./up.sh` also runs `java/install-jdk.sh`. `./bootstrap.sh` execs `./up.sh` with the same arguments.

There is no conventional systemd here. Cron and AOS stay up through vendored bash loops (`flock` + `nohup`) in this repo.

## After reboot or Update

No systemd: a reboot or an Update kills those loops. They do not come back by themselves. Apt packages, including a JDK, are often gone as well. `/workspace` persists. From the VM console:

```bash
cd /workspace/box-upkeep && ./up.sh
```

That one command runs the gate (`../box-access/up.sh`) and then AOS (`./aos/aos-up.sh`). When `java` or `javac` does not run, `./up.sh` installs `default-jdk`. On Ubuntu 24.04 that package depends on `openjdk-21-jdk`. Set `JDK_PACKAGE` to choose another apt package, such as `openjdk-17-jdk`. A JDK that already runs is left alone (`jdk: present`).

## Layout

`./up.sh` is the host orchestrator: gate, then AOS, then a JDK when `java` or `javac` does not run. The canonical AOS orchestrator is `aos/aos-up.sh`. It sources `aos/lib/common.sh`, then each `aos/steps/*.sh` in order. Steps share one shell. Each step is idempotent. `./aos-up.sh` only execs that entry.

`lib/common.sh` is shared by `./up.sh` and `java/install-jdk.sh` (paths, flags, the JDK check). AOS config and AOS flags live under `aos/`.

```text
up.sh                           # gate, then aos/aos-up.sh, then JDK if missing
bootstrap.sh                    # exec ./up.sh "$@"; same arguments
aos-up.sh                       # exec ./aos/aos-up.sh; same arguments
lib/common.sh                   # shared paths and flags for up.sh and the JDK
java/install-jdk.sh             # default-jdk when java or javac is missing
aos/aos-up.sh                   # canonical AOS orchestrator
aos/lib/common.sh               # AOS paths, config, flags
aos/config/aos.env              # default AOS URL, path, timezone
aos/steps/01-timezone.sh        # America/Sao_Paulo (cron ignores CRON_TZ)
aos/steps/02-cronie.sh          # install cronie; start crond if it is down
aos/steps/03-clone-aos.sh       # git clone AOS when the checkout is missing
aos/steps/04-calendar.sh        # aos up (calendar crontab + catch-up)
aos/steps/05-watchdogs.sh       # aos/units cron and aos watchdogs
aos/packages.txt                # cronie
aos/units/cron-watchdog.sh      # restart crond/cron
aos/units/aos-watchdog.sh       # aos up --watch-only
```

`up.sh` does not copy scripts into `/home/box`. Watchdogs run from this checkout (`aos/units/`). Logs and lock directories sit next to the unit scripts (`*.log`, `*.lock/`) and are gitignored.

The `aos/` directory in this repo is cold-start code. It is not the AOS checkout. The checkout defaults to `/workspace/aos`.

## Use

Cold start is the console command above. `./bootstrap.sh` does the same thing. Prefer `./up.sh`.

Pull first when this checkout should match the remote:

```bash
cd /workspace/box-upkeep
git pull
./up.sh
```

Gate only, or AOS only. A missing JDK is still installed afterward:

```bash
./up.sh --access-only
./up.sh --aos-only
```

Packages only (the flag is forwarded to both orchestrators; each repo defines what it installs). This repo then installs a missing JDK (`default-jdk`, or `JDK_PACKAGE`):

```bash
./up.sh --install-only
```

`./aos/aos-up.sh --install-only` (or `./aos-up.sh --install-only`) stops after timezone and cronie. It does not install a JDK. The JDK is not listed in `aos/packages.txt`.

Full AOS path without the keep-alive loops (`crond` is still started once by the cronie step; `aos up` still installs the crontab):

```bash
./aos/aos-up.sh --no-watchdogs
```

`./aos-up.sh --no-watchdogs` is the same command.

Skip the clone when `/workspace/aos` is already the checkout you want (or set `AOS_ROOT`):

```bash
./aos/aos-up.sh --skip-clone
```

Flags can be combined. `./up.sh` forwards `--install-only` and `--no-watchdogs` to both orchestrators. `--skip-clone` is passed only to the AOS entry. The JDK script takes no flags; `./up.sh` runs it when `java` or `javac` does not run. `./bootstrap.sh` and `./aos-up.sh` forward arguments unchanged.

`./up.sh --help` and `./aos/aos-up.sh --help` print the flags. `./aos-up.sh --help` prints the same AOS help.

## Failure policy

`./up.sh` runs the gate, then AOS. If one side fails, that failure is printed and the other side still runs. The process exits with the first non-zero status (gate, then AOS, then the JDK step). A missing `../box-access/up.sh` is a gate failure (status 127), not a silent skip.

The JDK step runs after the gate and AOS when `java` or `javac` does not run. It still runs under `--install-only`, `--access-only`, and `--aos-only`. If the gate fails and `--stop-on-error` is set, `./up.sh` exits before the JDK step. A JDK failure is printed and does not undo the sides that already ran. The exit status is the first non-zero of the gate, AOS, and the JDK step. A missing `java/install-jdk.sh` is a JDK failure (status 127) when a JDK is needed. A JDK that already runs is a one-line skip (`jdk: present`); the install script is not called.

`--stop-on-error` changes the gate/AOS order: a failing gate skips `aos/aos-up.sh` and the exit status is the gate's. The JDK step is not reached on that early exit. `--access-only` and `--aos-only` run one orchestrator on purpose. Those two flags cannot be combined. A missing JDK is still installed after the side that did run.

Inside `aos/aos-up.sh`, a step failure stops the later AOS steps. A failed `aos up` does not start the keep-alive loops. Fix the cause and run `./aos/aos-up.sh` again.

## What one AOS run does

`--install-only` runs steps 01 and 02 and stops. `--skip-clone` still runs step 03, which returns immediately. `--no-watchdogs` skips step 05. The JDK install is a `./up.sh` step, not one of these. Otherwise:

1. **`aos/steps/01-timezone.sh`** — Set the host localtime to `America/Sao_Paulo` (`BOX_TZ`). Debian cron and Debian cronie schedule in local time and ignore `CRON_TZ`, so AOS `0 0` is agency midnight only when the host zone is that zone.
2. **`aos/steps/02-cronie.sh`** — Install `cronie` from `aos/packages.txt` if it is missing. Start `/usr/sbin/crond` (or `/usr/sbin/cron`) once when no cron daemon is running.
3. **`aos/steps/03-clone-aos.sh`** — If `AOS_ROOT` (default `/workspace/aos`) has no `.git`, `git clone` `AOS_REPO_URL`. A checkout that is already present is left as-is (no pull). A path that exists and is not a git clone is an error. `--skip-clone` prints `clone: skipped` and does not fetch.
4. **`aos/steps/04-calendar.sh`** — Run `$AOS_ROOT/scripts/aos up` (crontab + catch-up, not `--watch-only`). A missing binary, a non-zero exit, `crontab-error:`, or `crontab-unavailable` fails the step.
5. **`aos/steps/05-watchdogs.sh`** — Stop a previous cron/AOS watchdog from this repo (`aos/units/`, a leftover pair started from the old repo-root `units/`, and a leftover copy under `/home/box/upkeep/` of those two scripts), then start `aos/units/cron-watchdog.sh` and `aos/units/aos-watchdog.sh`. Skipped with `--no-watchdogs`.

## AOS checkout

Default remote, also in `aos/config/aos.env`:

```text
https://github.com/n-huche/aos.git
```

Override without editing the file:

```bash
AOS_REPO_URL=https://github.com/n-huche/aos.git AOS_ROOT=/workspace/aos ./aos/aos-up.sh
```

An exported variable wins over `aos/config/aos.env`. The clone does not prompt (`GIT_TERMINAL_PROMPT=0`). This repo does not clone private life into the AOS checkout's `user/` tree (`/workspace/aos/user`). AOS needs that tree on disk for daily close; clone it yourself if you keep one. This repo does not contain tasks, dailies, or other AOS law.

The gate entry defaults to `../box-access/up.sh`. Override with `BOX_ACCESS_UP` (environment, or `BOX_ACCESS_UP` in `aos/config/aos.env` when it is not already set). `AOS_UP` overrides `./aos/aos-up.sh` (tests and unusual layouts). `JDK_INSTALL` overrides `./java/install-jdk.sh`. `JDK_PACKAGE` overrides the apt package name (default `default-jdk`).

## Keep-alive

| Unit | Behavior |
|---|---|
| `aos/units/cron-watchdog.sh` | Loop. If `crond` or `cron` is down, start it. `flock` so only one loop runs. Exponential backoff (5s–60s) when the binary is missing. |
| `aos/units/aos-watchdog.sh` | Loop. When `$AOS_ROOT/scripts/aos` exists, run `aos up --watch-only`. Does not install the crontab (that is step 04). Waits if the binary is not there yet. Same `flock` and backoff. |

The loops keep cron and AOS watch up if either process crashes. They are not systemd units, so a reboot or an Update stops them until the console command above starts them again. How you reach the box is `box-access`; this repo does not describe that path.

## Older `/home/box/upkeep` copies

Previous versions installed `/home/box/start.sh` and copied watchdogs into `/home/box/upkeep`, including copies of the gate. Those gate copies are not in this repo and are not installed anymore. Step 05 only replaces this repo's cron and aos loops (`aos/units/`, a leftover pair started from the old repo-root `units/`, and a leftover cron/aos pair under `/home/box/upkeep`). It does not start or stop the gate.

## What git does not store

- Watchdog logs and lock directories
- `.env` / `.env.*`
- The AOS checkout and its private `user/` tree
- Anything the gate stores (that repo, not this one)

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`).
- Do not consume the worker pool.
- Do not implement the gate in this repo. Do not vendor its packages, watchdogs, apt workarounds, secrets, or units. `./up.sh` executes `box-access/up.sh`, then this repo's own JDK install when `java` or `javac` does not run.
- Does not contain AOS law (tasks, daily). Sets host localtime so AOS `0 0` is agency midnight, installs cronie, clones the AOS repo when it is missing, keeps `aos up --watch-only` running, and installs a JDK when `java` or `javac` does not run.
- Never commit secrets.
