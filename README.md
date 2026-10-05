# ansible

Home-lab Ansible playbooks, loosely based on techno-tim's [launchpad](https://github.com/techno-tim/launchpad) repo. No roles, collections, or lint/test tooling — just an inventory, standalone playbooks, and templates.

## Usage

`ansible.cfg` sets the inventory, so run from the repo root:

```sh
ansible-playbook playbooks/<playbook>.yml
ansible-playbook playbooks/<playbook>.yml --check --diff   # dry run
ansible-playbook playbooks/<playbook>.yml --limit <host>   # single host
ansible-playbook playbooks/<playbook>.yml --syntax-check
ansible-inventory --graph                                  # verify group parsing
```

## Authentication

Every host is managed as a dedicated `ansible` user: SSH key only, passwordless sudo via `/etc/sudoers.d/ansible`, so no `-k`/`-K`. Plays set `become: true` themselves; nothing enables it from the inventory.

The control node is the `ansible` container on nelson-nuc (Homelab-IaC `stacks/nelson-nuc/ansible`), which replaces the old Pi (`ansible.lan`). Its private key lives on nelson-nuc in `~/containers/ansible/ssh/` (bind-mounted as the container's `/root/.ssh`, with `known_hosts`); the public key is committed as `files/ansible_ed25519.pub`. `authorized_keys` restricts it with `from="192.168.88.101"` (container traffic is NATed to nelson-nuc's LAN IP), so the key doesn't work from anywhere else. nelson-nuc itself overrides this with `automation_key_from` in the inventory, since the container reaches its own host from its Docker network.

New hosts are set up once with `playbooks/bootstrap.yml`, run as an existing account from a machine that can already log in:

```sh
ansible-playbook playbooks/bootstrap.yml -l <host> -e ansible_user=<existing user> -K
```

On Ubuntu 26.04+ (e.g. kirks-bar), `sudo` is sudo-rs, and the bootstrap fails with `Timeout (12s) waiting for privilege escalation prompt` because Ansible doesn't see its password prompt. Add `-e ansible_become_exe=sudo.ws` to use the original sudo, which Ubuntu still ships. Only the bootstrap needs this: afterwards the `ansible` user's sudo is passwordless, so there's no prompt.

If a server on the LAN is on the tailnet, it needs `tailscale set --accept-routes=false`. (Roaming clients like the laptop are the exception: they keep it on, see the Homelab-IaC README.) nelson-nuc advertises the LAN as a subnet route, and a LAN host that accepts it replies to LAN connections through Tailscale, so the control container's SSH times out (kirks-bar hit this).

## Inventory

`inventory/hosts` is an INI inventory. `[all:vars]` defaults every host to user `ansible` and `python3`.

| Group | Hosts | Purpose |
|---|---|---|
| `pis` | Pi-hole boxes | `pihole-update.yml` |
| `ubuntu` | nelson-nuc, quark-vm, kirks-bar | `updates.yml` (also reboots on an NVIDIA driver mismatch) |
| `komodo_periphery` | docker hosts running a standalone Periphery (kirks-bar) | `komodo-periphery.yml` |
| `docker` | children: `komodo_periphery`, `nvidia` | `docker.yml` |
| `nvidia` | docker hosts with an NVIDIA GPU (kirks-bar) | `nvidia.yml` |
| `nas_remount_restart` | hosts with containers binding `/mnt/nas` subdirectories (nelson-nuc, quark-vm, kirks-bar) | `nas-remount-restart.yml` |
| `db_backup` | docker hosts with database containers to back up (nelson-nuc, quark-vm, kirks-bar) | `db-backup.yml` |

`quark-vm.lan` is a CNAME for `quarks.lan`, so it's listed only once.

## Playbooks

| Playbook | Targets | What it does |
|---|---|---|
| `bootstrap.yml` | `-l <host>` | One-time creation of the `ansible` user (see Authentication). |
| `updates.yml` | `ubuntu` | apt dist-upgrade, reboot if required. |
| `pihole-update.yml` | `pis` | Updates Pi-hole. |
| `timezone.yml` | all hosts | Sets the timezone and configures timesyncd. |
| `docker.yml` | `docker` | Installs Docker + compose v2 and adds `docker_user` to the docker group. |
| `komodo-periphery.yml` | `komodo_periphery` | Deploys a standalone Komodo Periphery agent. |
| `nvidia.yml` | `nvidia` | Installs the NVIDIA driver + container toolkit so containers can use the GPU. |
| `nas-remount-restart.yml` | `nas_remount_restart` | Restarts the host's `nas_restart_containers` whenever `/mnt/nas` mounts. |
| `db-backup.yml` | `db_backup` | Nightly dumps of labeled database containers to the NAS. |

### nas-remount-restart.yml

A container that binds a subdirectory of the NAS share (e.g. `/mnt/nas/media/Books`) keeps whatever was there when it started: the empty mount point if the share wasn't mounted yet, or the old mount after a remount. `rslave` doesn't help, since the remount happens at `/mnt/nas`, above the bind. The playbook installs `nas-remount-restart.service`, `WantedBy=mnt-nas.mount`, which runs `docker restart` on the host's `nas_restart_containers` (container names, set per host in the inventory) each time the share mounts. Installing it restarts nothing.

### db-backup.yml

Installs `/usr/local/sbin/db-backup` and `/etc/cron.d/db-backup` (00:30 daily: before 01:00, since DST changeovers skip or repeat 01:00–03:00, and before CrashPlan's 03:00 scan of the share). The script backs up running containers by label, set in the Homelab-IaC compose files:

- `homelab.backup.postgres=true`: `pg_dumpall` as the container's `$POSTGRES_USER`, checked for the end-of-dump marker.
- `homelab.backup.sqlite=/path/a.db,/path/b.db`: SQLite's online `.backup` of each path (paths inside the container, which must be on a bind mount or volume), checked with `PRAGMA quick_check`. It runs as the file's owner, so any `-wal`/`-shm` files it creates aren't root-owned.

Dumps are gzipped into `/mnt/nas/backups/db/<host>/<YYYY-MM-DD>/`, keeping the newest 14 days (`db_backup_keep`). If `/mnt/nas` isn't mounted, the script exits without writing anything. The log is `/var/log/db-backup.log`, and the exit status is non-zero if any dump failed. Set `db_backup_push_url` to an Uptime Kuma push monitor URL to be alerted on failures or missed runs. Run `sudo db-backup` on a host to test.

Restore: `zcat <c>.sql.gz | docker exec -i <c> psql -U <user> -d postgres` into a fresh (empty-volume) container; for SQLite, stop the app and replace the file with the gunzipped copy, removing any `-wal`/`-shm` next to it.

### docker.yml

`docker_user` is `CHANGEME` in `[docker:vars]` until the host's account exists; set it per host. The play refuses the placeholder or a missing account.

Fresh hosts get Docker's official apt repo (like nelson-nuc). Hosts that already have Docker keep their engine and only get the matching compose plugin — `docker-compose-plugin` for docker-ce, Ubuntu's `docker-compose-v2` for docker.io (like quark-vm) — since swapping engines would stop running containers.

### komodo-periphery.yml

Runs Periphery as `docker_user` (compose project in that user's `~/containers/komodo-periphery`), connecting outbound to Komodo Core on nelson-nuc over Tailscale. Imports `docker.yml` first.

- First run on a host needs a privileged onboarding key created in Core: `-e komodo_onboarding_key=<key>`. Later runs don't; delete the key in Core once onboarding succeeds. Onboarding state is detected from `core.pub` in the `keys` volume.
- `komodo_version` must match Core.
- Never target nelson-nuc — its Periphery is part of the Core compose project.

Background lives in the Homelab-IaC repo's `Komodo-PoC.md` / `Komodo-Migration.md`.

### nvidia.yml

Installs the headless NVIDIA driver (`nvidia_driver_branch`, default `580-server`, the last branch that supports Pascal cards like kirks-bar's Quadro P1000) with Canonical's prebuilt kernel modules instead of DKMS. It also blacklists nouveau, installs `nvidia-container-toolkit` from NVIDIA's apt repo, and registers the `nvidia` runtime with Docker. The first run reboots the host to load the driver, then checks `nvidia-smi` on the host and in a container. Imports `docker.yml` first.

Kernel and NVIDIA packages are excluded from unattended-upgrades (`/etc/apt/apt.conf.d/51unattended-upgrades-nvidia`), so they only move when `updates.yml` runs. A driver upgrade breaks NVML until reboot (`Driver/library version mismatch`), and a new kernel installed without its nvidia module boots with no driver. `updates.yml` reboots on a driver mismatch as well as on `reboot-required`. The driver isn't `apt-mark hold`: each kernel's module package requires the matching driver version, so a hold would block kernel updates.

## Layout

- `inventory/hosts` — the inventory.
- `playbooks/` — one playbook per task; each targets a group via `hosts:`.
- `files/` — static files for playbooks; `ansible_ed25519.pub` is the control container's public key.
- `templates/` — Jinja templates, referenced from playbooks with paths relative to the playbook dir (e.g. `src=../templates/timesyncd.conf`). `timesyncd.conf` points NTP at the local server `192.168.88.101`, falling back to `time.cloudflare.com`.
