#!/bin/bash
#
# Nightly ZFS backup of a Linux disk node (connect) to silo6, in the spirit of the
# silos' /usr/local/sbin/zfs_backup.sh: one snapshot per day, incremental send of
# the difference since yesterday's snapshot, keep only yesterday and today locally.
# Nothing is stopped: the datasets hold pod disk volumes (databases), and a ZFS
# snapshot is atomic - what the database would find after a power cut; the
# databases also dump themselves logically from inside their pods.
#
# On silo6: root must be able to log in without a password from this box
# (its /root/.ssh/id_ed25519.pub in silo6's authorized_keys).
#
# Usage: zfs_backup_linux.sh [-f]      (-f: take an extra snapshot today)
#
myhostname=`hostname -s`
src="tank/data"
backuphost="silo6.sciencedata.dk"
destination="basin/backup/$myhostname"
today=`date +%Y-%m-%d`
log() { echo "`date '+%F %T'` zfs_backup: $*"; }

force=""
while getopts "f" flag; do case "$flag" in f) force=yes;; esac; done

# One at a time
exec 9>/run/zfs_backup.lock
flock -n 9 || { log "another backup is still running; exiting"; exit 1; }

ssh -o BatchMode=yes -o ConnectTimeout=20 root@$backuphost true || { log "cannot ssh to $backuphost"; exit 1; }

src_name=`echo $src | sed -E 's|^[^/]+/||'`
snapshot_today="$src@$today"
if zfs list -t snapshot -o name -H "$snapshot_today" >/dev/null 2>&1; then
	if [ "$force" != "yes" ]; then log "$snapshot_today already exists; nothing done"; exit 0; fi
	snapshot_today="$src@$today-`date +%H%M%S`"
fi

# The newest existing local snapshot is the base for the incremental send
previous=`zfs list -t snapshot -o name -H -s creation -r $src | grep "^$src@" | tail -1`

log "creating $snapshot_today"
zfs snapshot -r "$snapshot_today" || { log "snapshot failed"; exit 1; }

if ! ssh root@$backuphost "zfs list $destination/$src_name" >/dev/null 2>&1; then
	log "first backup: full send of $snapshot_today to $backuphost:$destination"
	ssh root@$backuphost "zfs create -p $destination" >/dev/null 2>&1
	zfs send -R "$snapshot_today" | ssh root@$backuphost "zfs receive -Fduv $destination"
	exit $?
fi

if [ -z "$previous" ]; then
	log "no previous local snapshot to send from; the receiving side has `ssh root@$backuphost "zfs list -t snapshot -o name -H -r $destination/$src_name | tail -1"` - resolve by hand"
	exit 1
fi
previous_name=`echo $previous | sed -E 's|^[^/]+/||'`
if ! ssh root@$backuphost "zfs list -t snapshot $destination/$previous_name" >/dev/null 2>&1; then
	log "$previous is not on $backuphost; rolling the receiving side back to its newest snapshot and resending from there"
	remote_latest=`ssh root@$backuphost "zfs list -t snapshot -o name -H -s creation -r $destination/$src_name | tail -1"`
	local_equiv=`echo $remote_latest | sed -E "s|^$destination/[^@]+|$src|"`
	if ! zfs list -t snapshot -o name -H "$local_equiv" >/dev/null 2>&1; then
		log "no local copy of $remote_latest; cannot continue incrementally - resolve by hand"; exit 1
	fi
	ssh root@$backuphost "zfs rollback -r $remote_latest"
	previous="$local_equiv"
fi

log "incremental send $previous -> $snapshot_today"
zfs send -R -i "$previous" "$snapshot_today" | ssh root@$backuphost "zfs receive -duv $destination" || { log "send failed; keeping $previous"; exit 1; }

# Keep only the two newest local snapshots (today and its base); the history lives on silo6
zfs list -t snapshot -o name -H -s creation -r $src | grep "^$src@" | head -n -2 | while read s; do
	log "destroying local $s"; zfs destroy -r "$s"
done
log "done"
