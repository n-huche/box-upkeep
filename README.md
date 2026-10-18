# box-upkeep

Keeps AOS alive after a reboot or an Update on the Grok Bot / Cursor VM. It is not AOS law.

The gate is not implemented here. Nothing from [`box-access`](https://github.com/n-huche/box-access) is vendored: no gate packages, no gate watchdogs, no gate apt workarounds, no gate secrets, no copies of its units or scripts. `./up.sh` executes that repo's orchestrator (`../box-access/up.sh`, or `BOX_ACCESS_UP`), then the AOS entry (`./aos/aos-up.sh`, or `AOS_UP`). When `java` or `javac` does not run, `./up.sh` also runs `java/install-jdk.sh`. When `mvn -v` does not run, it runs `java/install-maven.sh` after the JDK. When `gh --version` does not run, it runs `gh/install-gh.sh` after Maven. `./bootstrap.sh` execs `./up.sh` with the same arguments.

There is no conventional systemd here. Cron and AOS stay up through vendored bash loops (`flock` + `nohup`) in this repo.

## After reboot or Update

No systemd: a reboot or an Update kills those loops. They do not come back by themselves. Apt packages, including a JDK and Maven, are often gone as well. `/workspace` persists. From the VM console:

```bash
cd /workspace/box-infra/box-upkeep && ./up.sh
```

That one command runs the gate (`../box-access/up.sh`) and then AOS (`./aos/aos-up.sh`). When `java` or `javac` does not run, `./up.sh` installs `default-jdk`. On Ubuntu 24.04 that package depends on `openjdk-21-jdk`. Set `JDK_PACKAGE` to choose another apt package, such as `openjdk-17-jdk`. A JDK that already runs is left alone (`jdk: present`). When `mvn -v` does not run, `./up.sh` then installs the apt package `maven`. On Debian 13 (trixie) that package is Maven 3.9.9, and it runs on the JDK 21 from `default-jdk`. Set `MAVEN_PACKAGE` to choose another apt package. A Maven that already runs is left alone (`maven: present`). When `gh --version` does not run, `./up.sh` adds the official GitHub CLI apt repository and installs `gh`. The keyring is `/etc/apt/keyrings/githubcli-archive-keyring.gpg` and the source is `https://cli.github.com/packages`. A `gh` that already runs is left alone (`gh: present`).

Every run then checks `gh auth status` for `github.com` in `GH_CONFIG_DIR` (default `/home/box/.config/gh`). That directory survives a wipe. `gh` is started with `GH_TOKEN` and `GITHUB_TOKEN` removed from its environment, so an ambient token cannot change the result. When the persisted account is `GH_EXPECTED_USER` (default `n-huche`), the step runs `gh auth setup-git --hostname github.com`. When github.com is logged out and `/home/box/.config/box-access/secrets.env` contains a `GH_TOKEN` line, only that assignment is read. That file is the chmod 600 file written by box-access step 02. The value is passed on stdin to `gh auth login --hostname github.com --git-protocol https --with-token`. A successful login of the expected account runs `gh auth setup-git`. The token is never printed, including under `set -x` and on a failed login. A missing `GH_TOKEN`, a failed login, or a different account prints a warning and the command `gh auth login --hostname github.com`. Those warnings leave the exit status unchanged. Only a failed `gh` install counts toward it.

## Layout

`./up.sh` is the host orchestrator: gate, then AOS, then a JDK when `java` or `javac` does not run, then Maven when `mvn -v` does not run, then GitHub CLI when `gh --version` does not run. The canonical AOS orchestrator is `aos/aos-up.sh`. It sources `aos/lib/common.sh`, then each `aos/steps/*.sh` in order. Steps share one shell. Each step is idempotent.

`lib/common.sh` is shared by `./up.sh`, `java/install-jdk.sh`, `java/install-maven.sh`, and `gh/install-gh.sh` (paths, flags, and the JDK, Maven, and GitHub CLI checks). AOS config and AOS flags live under `aos/`.

```text
up.sh                           # gate, then aos/aos-up.sh, then JDK, Maven, and gh if missing
bootstrap.sh                    # exec ./up.sh "$@"; same arguments
lib/common.sh                   # shared paths and flags for up.sh, the JDK, Maven, and gh
java/install-jdk.sh             # default-jdk when java or javac is missing
java/install-maven.sh           # maven when mvn -v does not run
gh/install-gh.sh                # official gh apt repo when gh --version does not run
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

Cold start is the console command above. `./bootstrap.sh` does the same thing; prefer `./up.sh`. Pull first when this checkout should match the remote:

```bash
cd /workspace/box-infra/box-upkeep
git pull
./up.sh
```

| Flag | `./up.sh` | `./aos/aos-up.sh` |
|---|---|---|
| `--install-only` | Forwarded to both orchestrators; each repo defines what it installs | Steps 01 and 02, then stop |
| `--no-watchdogs` | Forwarded to both orchestrators | Skip step 05 (`crond` still starts once; `aos up` still installs the crontab) |
| `--skip-clone` | Forwarded to the AOS entry only | Step 03 prints `clone: skipped` (use when `/workspace/aos` or `AOS_ROOT` is already the checkout you want) |
| `--access-only` | Gate only | — |
| `--aos-only` | AOS only | — |
| `--stop-on-error` | A failing gate skips AOS, the JDK step, the Maven step, and the GitHub CLI step | — |

Flags combine, except `--access-only` with `--aos-only`. `--help` prints them. `./bootstrap.sh` forwards arguments unchanged.

The JDK, Maven, and GitHub CLI steps belong to `./up.sh`, not to `aos/aos-up.sh` (none of those packages is in `aos/packages.txt`). They run after the gate and AOS under every flag, unless `--stop-on-error` already exited. The Maven step runs immediately after the JDK, and the GitHub CLI step runs immediately after Maven. When `java` or `javac` does not run, the JDK step installs `default-jdk` (or `JDK_PACKAGE`); a JDK that already runs is a one-line skip (`jdk: present`). When `mvn -v` does not run, the Maven step installs `maven` (or `MAVEN_PACKAGE`); a Maven that already runs is a one-line skip (`maven: present`). When `gh --version` does not run, the GitHub CLI step installs `gh` from `https://cli.github.com/packages`; a `gh` that already runs is a one-line skip (`gh: present`). The login check runs whenever `gh --version` succeeds.

## Failure policy

- `./up.sh` runs the gate, then AOS, then the JDK step, then the Maven step, then the GitHub CLI step. A failing side is printed and the next one still runs.
- The exit status is the first non-zero of gate, AOS, JDK, Maven, and GitHub CLI. A missing entry (`../box-access/up.sh`, `aos/aos-up.sh`, `java/install-jdk.sh`, `java/install-maven.sh`, `gh/install-gh.sh`) fails that side with status 127, not a silent skip.
- A missing github.com login, a missing `GH_TOKEN`, a failed `gh auth login`, or an account other than `GH_EXPECTED_USER` prints a warning and leaves the exit status unchanged. Only a failed `gh` install counts for that side.
- `--stop-on-error`: a failing gate exits with the gate's status. AOS, the JDK step, the Maven step, and the GitHub CLI step do not run.
- A JDK, Maven, or GitHub CLI failure does not undo the sides that already ran.
- Inside `aos/aos-up.sh`, a failed step stops the later steps. A failed `aos up` does not start the keep-alive loops. Fix the cause and run `./aos/aos-up.sh` again.

## What one AOS run does

Flags change this as in the table above. Otherwise:

1. **`aos/steps/01-timezone.sh`** — Set the host localtime to `America/Sao_Paulo` (`BOX_TZ`). Debian cron and Debian cronie schedule in local time and ignore `CRON_TZ`, so AOS `0 0` is agency midnight only when the host zone is that zone.
2. **`aos/steps/02-cronie.sh`** — Install `cronie` from `aos/packages.txt` if it is missing. Start `/usr/sbin/crond` (or `/usr/sbin/cron`) once when no cron daemon is running.
3. **`aos/steps/03-clone-aos.sh`** — If `AOS_ROOT` (default `/workspace/aos`) has no `.git`, `git clone` `AOS_REPO_URL`. A checkout that is already present is left as-is (no pull). A path that exists and is not a git clone is an error. `--skip-clone` prints `clone: skipped` and does not fetch.
4. **`aos/steps/04-calendar.sh`** — Run `$AOS_ROOT/scripts/aos up` (crontab + catch-up, not `--watch-only`). `AOS_ROOT` is resolved with `realpath` before that run, so the crontab stores the canonical checkout. A symlink path in that crontab that lands inside this repo or inside `AOS_ROOT` is rewritten to the real path. A missing binary, a non-zero exit, `crontab-error:`, or `crontab-unavailable` fails the step.
5. **`aos/steps/05-watchdogs.sh`** — Start `aos/units/cron-watchdog.sh` and `aos/units/aos-watchdog.sh` from the real path of this checkout. A watchdog already running as that same file (the path you typed, or a symlink to it) is left in place. A watchdog still running from another path — a previous checkout, the old repo-root `units/`, or `/home/box/upkeep/` — is stopped and replaced. The AOS watch process is not stopped. Skipped with `--no-watchdogs`.

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

The gate entry defaults to the sibling `../box-access/up.sh`, taken from the real path of this checkout (on the box, `/workspace/box-infra/box-access/up.sh`). Override with `BOX_ACCESS_UP` (environment, or `BOX_ACCESS_UP` in `aos/config/aos.env` when it is not already set). `AOS_UP` overrides `./aos/aos-up.sh` (tests and unusual layouts). `JDK_INSTALL` overrides `./java/install-jdk.sh`. `JDK_PACKAGE` overrides the apt package name (default `default-jdk`). `MAVEN_INSTALL` overrides `./java/install-maven.sh`. `MAVEN_PACKAGE` overrides the apt package name (default `maven`). `GH_INSTALL` overrides `./gh/install-gh.sh`. `GH_EXPECTED_USER` overrides the account that may run `gh auth setup-git` (default `n-huche`). `GH_CONFIG_DIR` overrides the persisted config directory (default `/home/box/.config/gh`). `BOX_ACCESS_SECRETS` overrides the secrets file whose `GH_TOKEN` line is read (default `/home/box/.config/box-access/secrets.env`).

## Keep-alive

| Unit | Behavior |
|---|---|
| `aos/units/cron-watchdog.sh` | Loop. If `crond` or `cron` is down, start it. `flock` so only one loop runs for this file. Exponential backoff (5s–60s) when the binary is missing. |
| `aos/units/aos-watchdog.sh` | Loop. When `$AOS_ROOT/scripts/aos` exists, run `aos up --watch-only` only if that watch is not already up (pidfile or realpath). Does not install the crontab (that is step 04). Waits if the binary is not there yet. Same `flock` and backoff. |

Identity is the real path of the unit script, or the pid recorded in its lock file. Invoking `./up.sh` through a symlink, through the real path, or through an old path that is the same file does not start a second loop. A loop whose script is a different file is replaced by the one from this checkout. Replacing that loop does not restart `aos watch` when the watch pidfile or command line already belongs to `AOS_ROOT` (default `/workspace/aos`).

The loops keep cron and AOS watch up if either process crashes. They are not systemd units, so a reboot or an Update stops them until the console command above starts them again. How you reach the box is `box-access`; this repo does not describe that path.

## Older `/home/box/upkeep` copies

Previous versions installed `/home/box/start.sh` and copied watchdogs into `/home/box/upkeep`, including copies of the gate. Those gate copies are not in this repo and are not installed anymore. Step 05 replaces a cron or aos loop whose script is not the real file in `aos/units/` (a previous checkout, the old repo-root `units/`, or a leftover pair under `/home/box/upkeep`). It does not start or stop the gate, and it does not restart an AOS watch that is already running.

## What git does not store

- Watchdog logs and lock directories
- `.env` / `.env.*`
- The AOS checkout and its private `user/` tree
- Anything the gate stores (that repo, not this one)

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`).
- Do not consume the worker pool.
- Do not implement the gate in this repo. Do not vendor its packages, watchdogs, apt workarounds, secrets, or units. `./up.sh` executes `box-access/up.sh`, then this repo's own JDK install when `java` or `javac` does not run, then its own Maven install when `mvn -v` does not run, then its own GitHub CLI install when `gh --version` does not run.
- Does not contain AOS law (tasks, daily). Sets host localtime so AOS `0 0` is agency midnight, installs cronie, clones the AOS repo when it is missing, keeps `aos up --watch-only` running, and installs a JDK when `java` or `javac` does not run, Maven when `mvn -v` does not run, and GitHub CLI when `gh --version` does not run.
- Never commit secrets. Never print, copy, or write a GitHub token. The login check reads only the `GH_TOKEN` line from the gate's chmod 600 secrets file and passes that value to `gh` on stdin.
