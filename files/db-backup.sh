#!/usr/bin/env bash
# Managed by homelab-ansible (playbooks/db-backup.yml)
#
# Dumps the databases of every running container labeled for backup into
# $DB_BACKUP_DEST/<host>/<YYYY-MM-DD>/ on the NAS, keeping the newest $DB_BACKUP_KEEP days.
#
#   homelab.backup.postgres=true                   pg_dumpall as the container's $POSTGRES_USER
#   homelab.backup.sqlite=/app/data/a.db,/b.db     sqlite3 .backup of each path (paths inside the container)
#
# SQLite paths must be on a bind mount or volume; they're read from the host side. The online
# .backup API is safe while the app is writing, so nothing is stopped.
set -euo pipefail

nas=/mnt/nas
dest_root=${DB_BACKUP_DEST:-/mnt/nas/backups/db}
keep=${DB_BACKUP_KEEP:-14}
push_url=${DB_BACKUP_PUSH_URL:-}
host=$(hostname -s)
dest="$dest_root/$host/$(date +%F)"
failed=0
count=0

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

work=$(mktemp -d /var/tmp/db-backup.XXXXXX)
trap 'rm -rf "$work"' EXIT
# sqlite3 runs as each database's owner (see below), so it needs to create files here
chmod 0733 "$work"
mkdir "$work/mnt"
mkdir -p "$dest"

log "start -> $dest"

for c in $(docker ps --filter label=homelab.backup.postgres=true --format '{{.Names}}'); do
    out="$work/$c.sql.gz"
    if docker exec "$c" sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip >"$out" &&
        zcat "$out" | tail -n 3 | grep -q 'PostgreSQL database cluster dump complete' &&
        cp "$out" "$dest/"; then
        log "ok   $c ($(du -h "$out" | cut -f1))"
        count=$((count + 1))
    else
        log "FAIL $c: pg_dumpall"
        failed=1
    fi
done

for c in $(docker ps --filter label=homelab.backup.sqlite --format '{{.Names}}'); do
    mounts=$(docker inspect -f '{{json .Mounts}}' "$c")
    IFS=, read -ra paths <<<"$(docker inspect -f '{{index .Config.Labels "homelab.backup.sqlite"}}' "$c")"
    for p in "${paths[@]}"; do
        # Container path -> host path, via the longest mount destination that contains it
        src=$(jq -r --arg p "$p" '
            [.[] | select(.Destination as $d | $p == $d or ($p | startswith($d + "/")))]
            | max_by(.Destination | length)
            | if . == null then "" else .Source + $p[(.Destination | length):] end' <<<"$mounts")
        if [[ -z $src || ! -f $src ]]; then
            log "FAIL $c: $p is not a file on a mount"
            failed=1
            continue
        fi
        tmp="$work/$c.$(basename "$p")"
        # Run as the file's owner: if sqlite3 has to create the -wal/-shm files, root-owned
        # ones would lock the app out of its own database. The owner can't traverse
        # /var/lib/docker to reach a volume, so the database's directory is bind-mounted at
        # $work/mnt in a private mount namespace and opened from there.
        if unshare -m --propagation private sh -c '
            mount --bind "$1" "$2" &&
                exec setpriv --reuid="$3" --regid="$4" --clear-groups sqlite3 "$2/$5" ".backup $6"' \
            _ "$(dirname "$src")" "$work/mnt" "$(stat -c %u "$src")" "$(stat -c %g "$src")" \
            "$(basename "$src")" "$tmp" &&
            [[ $(sqlite3 "$tmp" 'PRAGMA quick_check') == ok ]] &&
            gzip "$tmp" && cp "$tmp.gz" "$dest/"; then
            log "ok   $c $p ($(du -h "$tmp.gz" | cut -f1))"
            count=$((count + 1))
        else
            log "FAIL $c: $p"
            failed=1
        fi
    done
done

# Keep the newest $keep day directories
find "$dest_root/$host" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' | sort | head -n "-$keep" |
    while read -r old; do
        rm -rf -- "$old" && log "pruned $old"
    done

if ((failed)); then
    log "done with failures ($count ok)"
    push down "failures, $count ok"
    exit 1
fi
log "done ($count ok)"
push up "$count ok"
