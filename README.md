# box-upkeep

The host: first boot after a VM reset, and babysitting after reboot or Update. It is not the gate (`box-access`) and it is not AOS.

Identity (Tailscale login, purge, `tailscale up`) stays in `box-access`. This repo clones siblings if they are missing, runs that gate, then keeps processes up.

## First boot (VM reset)

Console of the VM — not SSH. One clone, then this script (it asks for GitHub, Tailscale keys via the gate, and an SSH public key if `authorized_keys` is empty):

```bash
cd /workspace
git clone https://github.com/n-huche/box-upkeep.git
cd box-upkeep
./bootstrap.sh
```

`./bootstrap.sh` (default):

1. Clone `box-access`, `aos`, and private `aos-user` into `aos/user` if missing (`GITHUB_OWNER` from this repo's `origin`, or `n-huche`)
2. `gh auth login` only if `aos-user` still needs cloning
3. Run `box-access/bootstrap.sh` (packages + recovery; Tailscale keys prompt there)
4. Prompt for an SSH public key if `~/.ssh/authorized_keys` is empty (empty line skips)
5. Install watchdogs + `/home/box/start.sh` and start them

Idempotent if the trees already exist: skips clones, the gate prints `gate-ok` when state is present, skips the SSH prompt when a key is already there.

`--install-only`: packages + scripts on disk, no clones, no gate recovery, no start.

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

1. Starts the units in `/home/box/upkeep/`.
2. If AOS exists, calls `aos up` **once** (calendar crontab + catch-up). An AOS failure does not abort upkeep.

From your machine (same tailnet):

```text
ssh -p 2222 box@cursor
```

Host key is new after a reset; the Mac will warn.

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`).
- Do not consume the worker pool.
- Do not create a Tailscale identity; call `box-access` for that.
- Does not contain AOS law (tasks, daily, agency timezone).
- sshd does not listen on `0.0.0.0`; only the Tailscale IP.
- Never commit API keys, auth keys, or SSH private keys.
