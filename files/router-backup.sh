#!/usr/bin/env bash
# Managed by homelab-ansible (playbooks/router-backup.yml)
#
# Backs up the MikroTik router over SSH to $ROUTER_BACKUP_DEST on the NAS and keeps the newest
# $ROUTER_BACKUP_KEEP of each kind:
#   router_<date>.rsc     `/export show-sensitive`: readable, diffable, and restorable onto any
#                         RouterOS device (paste or `/import`). Doesn't include user passwords.
#   router_<date>.backup  `/system backup save`: a full binary backup (users and passwords included),
#                         only restorable onto this same router model. Unencrypted.
# The binary backup is written to the router's flash first (16 MiB, little free), so it's deleted
# there once it's copied, including when the run fails.
set -euo pipefail

nas=/mnt/nas
dest=${ROUTER_BACKUP_DEST:-/mnt/nas/backups/router}
keep=${ROUTER_BACKUP_KEEP:-30}
router=${ROUTER_BACKUP_TARGET:-Ansible@router.lan}
key=${ROUTER_BACKUP_KEY:-/home/nelson/containers/ansible/ssh/id_ed25519}
known_hosts=${ROUTER_BACKUP_KNOWN_HOSTS:-/home/nelson/containers/ansible/ssh/known_hosts}
push_url=${ROUTER_BACKUP_PUSH_URL:-}

# Name of the temporary file on the router's flash
remote=ansible-nightly

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

ssh_opts=(-o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes
          -o "UserKnownHostsFile=$known_hosts" -i "$key")
ros() { ssh "${ssh_opts[@]}" "$router" "$1"; }

# Touch the share first so an idle automount mounts it, then require the real CIFS mount:
# mountpoint(1) also succeeds on the bare autofs placeholder.
ls "$nas" >/dev/null 2>&1 || true
findmnt -n -t cifs "$nas" >/dev/null || fail "$nas not mounted"
mkdir -p "$dest"

# Build both files locally and check them, then copy, so a failed run never leaves a partial file on the NAS
tmp=$(mktemp -d)
cleanup() {
    rm -rf -- "$tmp"
    ros "/file remove [find name=\"$remote.backup\"]" >/dev/null 2>&1 || log "WARN: couldn't remove $remote.backup from the router"
}
trap cleanup EXIT

stamp=$(date +%F)

ros "/export show-sensitive" >"$tmp/router_$stamp.rsc" || fail "export failed"
grep -q '^# software id' "$tmp/router_$stamp.rsc" && grep -q '^/ip address' "$tmp/router_$stamp.rsc" \
    || fail "export looks incomplete"

ros "/system backup save name=$remote dont-encrypt=yes" >/dev/null || fail "backup save failed"
scp "${ssh_opts[@]}" "$router:$remote.backup" "$tmp/router_$stamp.backup" >/dev/null || fail "copying the backup off the router failed"
# An unencrypted RouterOS backup starts with 88 ac a1 b1
[[ $(od -An -tx1 -N4 "$tmp/router_$stamp.backup" | tr -d ' \n') == 88aca1b1 ]] || fail "backup file has the wrong header"

for f in "$tmp"/router_"$stamp".*; do
    cp -- "$f" "$dest/" || fail "copy to $dest failed"
    log "wrote $dest/$(basename "$f") ($(stat -c %s "$f") bytes)"
done

# Keep the newest $keep of each kind (names sort by date)
for ext in rsc backup; do
    mapfile -t old < <(ls -1 "$dest"/router_*."$ext" 2>/dev/null | sort -r | tail -n +"$((keep + 1))")
    for f in "${old[@]}"; do
        rm -f -- "$f" && log "pruned $f"
    done
done

push up "ok"
