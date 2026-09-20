# box-upkeep

The host: first boot after a VM reset, and babysitting after reboot or Update. It is not the gate and it is not AOS.

Identity (Tailscale login, purge, `authorized_keys`) is **only** `box-access`. This repo clones that gate if it is missing and runs its bootstrap. Then it keeps processes up — including `tailscaled` and `sshd`.

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
3. Run `box-access/bootstrap.sh` (identity, keys, one-shot SSH)
4. Install watchdogs + `/home/box/start.sh` and start them

`--install-only`: packages + scripts on disk, no clones, no gate, no start.

## Units

| Unit | What it keeps |
|---|---|
| `tailscale` | `tailscaled` with the existing state (does not create identity; that is `box-access`) |
| `sshd` | `sshd` on Tailscale IPv4 only, port **2222** |
| `cron` | `cron` daemon (AOS installs the calendar crontab) |
| `aos` | `aos up --watch-only` if `/workspace/aos` exists |

A missing or failing unit does not block the others.

## Layout

In git:

```text
bootstrap.sh          # birth + install + start
start.sh              # cold start (copied to /home/box/start.sh)
packages.txt          # cron
units/*.sh            # one watchdog per process
```

On the box, after bootstrap:

```text
/home/box/start.sh
/home/box/upkeep/     # units, logs, locks
```

## After reboot or Update

```bash
cd /workspace/box-upkeep
git pull
./bootstrap.sh
```

or `/home/box/start.sh` if the scripts are already installed.

`start.sh`:

1. Starts the units in `/home/box/upkeep/` (including Tailscale and sshd).
2. If AOS exists, calls `aos up` **once** (calendar crontab + catch-up). An AOS failure does not abort the host.

From your machine (same tailnet):

```text
ssh -p 2222 box@cursor
```

Host key is new after a reset; the Mac will warn.

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`).
- Do not consume the worker pool.
- Do not create a Tailscale identity or write `authorized_keys`. Clone `box-access` and run its bootstrap.
- Does not contain AOS law (tasks, daily, agency timezone).
- sshd does not listen on `0.0.0.0`; only the Tailscale IP (the watchdog starts it that way).
- Never commit API keys, auth keys, or SSH private keys.
