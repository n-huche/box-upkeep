# box-upkeep

Babá de processos desta box. Trabalha para o portão (`box-access`) e para o AOS: se existirem nesta máquina, mantém-nos no ar. Não é o portão e não é o AOS.

Depois de reboot ou Update da box, os daemons não voltam sozinhos. Este repo instala watchdogs e um `start.sh` que os relança.

## Unidades

| Unidade | O que mantém |
|---|---|
| `tailscale` | `tailscaled` com o state já existente (não cria identidade; isso é `box-access`) |
| `sshd` | `sshd` só no IPv4 Tailscale, porta **2222** |
| `cron` | daemon `cron` (o crontab de calendário o AOS instala) |
| `aos` | `aos up --watch-only` se `/workspace/aos` existir |

Uma unidade em falta ou a falhar não impede as outras.

## Layout

No git:

```text
bootstrap.sh          # pacotes + instala em /home/box + start
start.sh              # cold start (cópia em /home/box/start.sh)
packages.txt          # cron
units/*.sh            # um watchdog por processo
```

Na box, depois do bootstrap:

```text
/home/box/start.sh
/home/box/upkeep/     # unidades, logs, locks
```

## Cold start

```bash
cd /workspace/box-upkeep
git pull
./bootstrap.sh
```

Se `../box-access/bootstrap.sh` existir, corre `--install-only` primeiro (pacotes Tailscale/sshd, sem arrancar processos).

`start.sh`:

1. Para leftovers de watchdogs em `/home/box/infra/` e `/home/box/keep/` se ainda existirem (não mata `tailscaled`/`sshd`).
2. Sobe as unidades em `/home/box/upkeep/`.
3. Se o AOS existir, chama `aos up` **uma vez** (crontab de calendário + catch-up). Falha do AOS não aborta o upkeep.

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
