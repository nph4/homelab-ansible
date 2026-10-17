#!/usr/bin/env bash
# Managed by homelab-ansible (playbooks/secrets-backup.yml)
#
# Tars the host-only secret files listed in /etc/secrets-backup/paths (one absolute path or glob per
# line) and encrypts the archive with age to the public keys in /etc/secrets-backup/recipients, writing
# $SECRETS_BACKUP_DEST/<host>/secrets_<YYYY-MM-DD>.tar.age and keeping the newest $SECRETS_BACKUP_KEEP.
# The plaintext tar is never written to disk: it's piped straight into age. The private key isn't on
# any host, so nothing here (or anyone reading the NAS) can decrypt the archives.
#
# A listed path that doesn't exist is a failure: the rest is still backed up, but the run exits
# non-zero, so a renamed or deleted secret doesn't silently drop out of the backup.
#
# Restore, on a machine holding the private key:
#   age -d -i key.txt secrets_<date>.tar.age | tar -tvf -          (list)
#   age -d -i key.txt secrets_<date>.tar.age | tar -xf - -C <dir>  (paths are relative to /)
set -euo pipefail

nas=/mnt/nas
conf=/etc/secrets-backup
dest_root=${SECRETS_BACKUP_DEST:-/mnt/nas/backups/secrets}
keep=${SECRETS_BACKUP_KEEP:-30}
push_url=${SECRETS_BACKUP_PUSH_URL:-}
host=$(hostname -s)
dest="$dest_root/$host"
out="$dest/secrets_$(date +%F).tar.age"
failed=0

log() { echo "$(date '+%F %T') $*"; }

push() {
    [[ -n $push_url ]] || return 0
    curl -fsS -m 10 -G "$push_url" --data-urlencode "status=$1" --data-urlencode "msg=$2" >/dev/null || log "WARN: push to monitor failed"
}

# Touching the share mounts it if the automount is armed; then refuse to write into the
# bare mount point on local disk.
ls "$nas" >/dev/null 2>&1 || true
if ! mountpoint -q "$nas"; then
    log "ERROR: $nas is not mounted"
    push down "$nas not mounted"
    exit 1
fi

# Expand each listed path or glob; paths go to tar relative to /
paths=()
while read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    matches=$(compgen -G "$line" || true)
    if [[ -z $matches ]]; then
        log "FAIL missing: $line"
        failed=1
        continue
    fi
    while read -r m; do paths+=("${m#/}"); done <<<"$matches"
done <"$conf/paths"

if ((${#paths[@]} == 0)); then
    log "ERROR: nothing to back up"
    push down "nothing to back up"
    exit 1
fi

mkdir -p "$dest"
tmp="$dest/.secrets.tar.age.tmp"
trap 'rm -f "$tmp"' EXIT
if tar -C / -cf - -- "${paths[@]}" | age -R "$conf/recipients" -o "$tmp" &&
    [[ $(head -c 21 "$tmp") == age-encryption.org/v1 ]]; then
    mv -f "$tmp" "$out"
    log "ok   ${#paths[@]} paths -> $out ($(du -h "$out" | cut -f1))"
else
    log "FAIL tar/age"
    push down "tar/age failed"
    exit 1
fi

# Keep the newest $keep archives
find "$dest" -maxdepth 1 -type f -name 'secrets_????-??-??.tar.age' | sort | head -n "-$keep" |
    while read -r old; do
        rm -f -- "$old" && log "pruned $old"
    done

if ((failed)); then
    log "done with failures"
    push down "missing paths"
    exit 1
fi
log "done"
push up "${#paths[@]} paths"
