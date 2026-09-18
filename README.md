# box-keep

Babá de processos desta box. Não é o portão (isso é `box-access`) e não é o AOS.

Depois de reboot ou Update da box, os daemons não voltam sozinhos. Este repo instala watchdogs e um `start.sh` que os relança.

## Unidades

| Unidade | O que mantém |
|---|---|
| `tailscale` | `tailscaled` com o state já existente (não cria identidade) |
| `sshd` | `sshd` só no IPv4 Tailscale, porta **2222** |
| `cron` | daemon `cron` (o crontab de calendário o AOS instala) |
| `aos` | `aos up --watch-only` se `/workspace/aos` existir |

Uma unidade em falta ou a falhar não impede as outras.

## Layout

No git:

```text
bootstrap.sh          # pacotes do keep + instala em /home/box + start
start.sh              # cold start (cópia em /home/box/start.sh)
packages.txt          # cron
units/*.sh            # um watchdog por processo
```

Na box, depois do bootstrap:

```text
/home/box/start.sh
/home/box/keep/       # unidades, logs, locks
```

## Cold start

```bash
cd /workspace/box-keep
git pull
./bootstrap.sh
```

Se `../box-access/bootstrap.sh` existir, corre `--install-only` primeiro (pacotes Tailscale/sshd, sem arrancar processos).

`start.sh`:

1. Para watchdogs velhos em `/home/box/infra/` (não mata `tailscaled`/`sshd`).
2. Sobe as unidades em `/home/box/keep/`.
3. Se o AOS existir, chama `aos up` **uma vez** (crontab de calendário + catch-up). Falha do AOS não aborta o keep.

Da tua máquina (mesmo tailnet):

```text
ssh -p 2222 box@<tailscale-ipv4>
```

## Regras

- Não toca na plataforma Grok Bot/Cursor (`sand-*`, `.cursor`, `chrome-profile`).
- Não consome pool de workers.
- Não cria identidade Tailscale.
- Não contém lei do AOS (tasks, daily, timezone da agência).
- sshd não escuta `0.0.0.0`; só o IP Tailscale.
