# box-upkeep

Process babysitter for this box. Works for the gate (`box-access`) and for AOS: if they exist on this machine, it keeps them up. It is not the gate and it is not AOS.

After a reboot or an Update of the box, daemons do not come back by themselves. This repo installs watchdogs and a `start.sh` that relaunches them.

## Units

| Unit | What it keeps |
|---|---|
| `tailscale` | `tailscaled` with the existing state (does not create identity; that is `box-access`) |
| `sshd` | `sshd` on Tailscale IPv4 only, port **2222** |
| `cron` | `cronie` (`crond`). AOS still owns the calendar crontab. |
| `aos` | `aos up --watch-only` if `/workspace/aos` exists |

A missing or failing unit does not block the others.

## Layout

In git:

```text
bootstrap.sh          # packages + install into /home/box + start
start.sh              # cold start (copied to /home/box/start.sh)
packages.txt          # cronie
units/timezone.sh     # host localtime; not a watchdog
units/*.sh            # one watchdog per process
```

On the box, after bootstrap:

```text
/home/box/start.sh
/home/box/upkeep/     # units, logs, locks
```

## Cold start

```bash
cd /workspace/box-upkeep
git pull
./bootstrap.sh
```

If `../box-access/bootstrap.sh` exists, it runs `--install-only` first (Tailscale/sshd packages, no processes).

`start.sh`:

1. Sets host localtime to `America/Sao_Paulo` (Debian cron/cronie ignore `CRON_TZ` and schedule in local time).
2. Stops any already-running upkeep watchdogs, then starts the units in `/home/box/upkeep/` (so binaries and locks re-resolve).
3. If AOS exists, calls `aos up` **once** (calendar crontab + catch-up). An AOS failure does not abort upkeep.

From your machine (same tailnet):

```text
ssh -p 2222 box@<tailscale-ipv4>
```

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`).
- Do not consume the worker pool.
- Do not create a Tailscale identity.
- Does not contain AOS law (tasks, daily). Sets host localtime to `America/Sao_Paulo` so AOS `0 0` is agency midnight.
- sshd does not listen on `0.0.0.0`; only the Tailscale IP.
