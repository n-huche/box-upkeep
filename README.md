# box-upkeep

The host: first boot after a VM reset, and babysitting after reboot or Update. It is not the gate and it is not AOS.

Tailscale and SSH are **only** `box-access`. This repo clones that gate if it is missing and runs its bootstrap. It does not configure identity, `sshd`, or `authorized_keys`.

## First boot (VM reset)

Console of the VM — not SSH:

```bash
cd /workspace
git clone https://github.com/n-huche/box-upkeep.git
cd box-upkeep
./bootstrap.sh
```

`./bootstrap.sh` (default):

1. Clone `box-access`, `aos`, and private `aos-user` into `aos/user` if missing (`GITHUB_OWNER` from this repo's `origin`, or `n-huche`)
2. `gh auth login` only if `aos-user` still needs cloning
3. Run `box-access/bootstrap.sh` (Tailscale, SSH keys, `sshd`)
4. Install cron/AOS watchdogs + `/home/box/start.sh` and start them

`--install-only`: packages + scripts on disk, no clones, no gate, no start.

## Units

| Unit | What it keeps |
|---|---|
| `cron` | `cron` daemon (AOS installs the calendar crontab) |
| `aos` | `aos up --watch-only` if `/workspace/aos` exists |

A missing or failing unit does not block the others. Tailscale and `sshd` watchdogs live in `box-access` (`/home/box/access/`).

## Layout

In git:

```text
bootstrap.sh          # birth + install + start
start.sh              # cold start (copied to /home/box/start.sh)
packages.txt          # cron
units/cron-watchdog.sh
units/aos-watchdog.sh
```

On the box, after bootstrap:

```text
/home/box/start.sh
/home/box/upkeep/     # cron + aos units, logs, locks
/home/box/access/     # installed by box-access, not this repo
```

## After reboot or Update

```bash
cd /workspace/box-upkeep
git pull
./bootstrap.sh
```

or `/home/box/start.sh` if the scripts are already installed. `start.sh` runs `/home/box/access/start.sh` when present (the gate's own process), then cron/AOS.

An AOS failure does not abort the host.

From your machine (same tailnet):

```text
ssh -p 2222 box@cursor
```

Host key is new after a reset; the Mac will warn.

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`).
- Do not consume the worker pool.
- Do not create a Tailscale identity, start `sshd`, or write `authorized_keys`. Clone `box-access` and run its bootstrap.
- Does not contain AOS law (tasks, daily, agency timezone).
- Never commit API keys, auth keys, or SSH private keys.
