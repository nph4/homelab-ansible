#!/usr/bin/env bash
# Managed by homelab-ansible (playbooks/pihole-backup.yml)
#
# Writes a Pi-hole Teleporter export (pihole.toml, gravity.db with lists/groups/clients, /etc/hosts)
# to $PIHOLE_BACKUP_DEST on the NAS and keeps the newest $PIHOLE_BACKUP_KEEP exports.
# Restore: Pi-hole web UI > Settings > Teleporter > Import, or `pihole-FTL --teleporter <zip>`.
set -euo pipefail

nas=/mnt/nas
dest=${PIHOLE_BACKUP_DEST:-/mnt/nas/backups/pihole}
keep=${PIHOLE_BACKUP_KEEP:-30}
push_url=${PIHOLE_BACKUP_PUSH_URL:-}

log() { echo "$(date '+%F %T') $*"; }

push() {
    [[ -n $push_url ]] || return 0
    curl -fsS -m 10 -G "$push_url" --data-urlencode "status=$1" --data-urlencode "msg=$2" >/dev/null || log "WARN: push to monitor failed"
}

fail() {
    log "ERROR: $1"
    push down "$1"
    exit 1
}

# Touch the share first so an idle automount mounts it, then require the real CIFS mount:
# mountpoint(1) also succeeds on the bare autofs placeholder.
ls "$nas" >/dev/null 2>&1 || true
findmnt -n -t cifs "$nas" >/dev/null || fail "$nas not mounted"
mkdir -p "$dest"

# pihole-FTL --teleporter writes pi-hole_<host>_teleporter_<date>.zip into the current directory.
# Build it locally, check it, then copy, so a failed run never leaves a partial file on the NAS.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
(cd "$tmp" && pihole-FTL --teleporter >/dev/null) || fail "teleporter export failed"
zip=$(find "$tmp" -maxdepth 1 -name 'pi-hole_*_teleporter_*.zip' -print -quit)
[[ -n $zip ]] || fail "teleporter wrote no zip"
unzip -tq "$zip" >/dev/null || fail "zip failed its integrity check"
unzip -l "$zip" | grep -q 'etc/pihole/pihole.toml' || fail "zip has no pihole.toml"
cp -- "$zip" "$dest/" || fail "copy to $dest failed"
log "wrote $dest/$(basename "$zip") ($(stat -c %s "$zip") bytes)"

# Keep the newest $keep exports (names sort by date)
mapfile -t old < <(ls -1 "$dest"/pi-hole_*_teleporter_*.zip 2>/dev/null | sort -r | tail -n +"$((keep + 1))")
for f in "${old[@]}"; do
    rm -f -- "$f" && log "pruned $f"
done

push up "ok"
