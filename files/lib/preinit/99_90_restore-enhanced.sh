#!/bin/sh
# shellcheck shell=busybox
# Enhanced restore for ImmortalWrt (Banana Pi BPI-R4) - preinit hook.
#
# /etc/preinit sources every file in /lib/preinit/* in ls order:
#   for pi_source_file in /lib/preinit/*; do . $pi_source_file; done
# The official config restore lives in /lib/preinit/80_mount_root: its
# do_mount_root() unpacks /sysupgrade.tgz (and /tmp/sysupgrade.tar) and is
# registered with `boot_hook_add preinit_main do_mount_root`. Hooks run in FIFO
# registration order, so this file must sort AFTER 80_mount_root - hence the name
# 99_90_restore-enhanced.sh (not restore-enhanced.sh). The hook function name is
# unique on purpose: boot_run_hook de-duplicates on PI_RAN_<func>.
#
# /opt is NOT mounted during preinit: /etc/fstab is an empty file, /opt comes
# from uci (/etc/config/fstab) through fstools /sbin/block, driven by
# /etc/init.d/fstab at START=11. btrfs is a module living in the overlay upper
# layer, so modprobe only works after mount_root - which is where this hook runs.
#
# Touching /dev/mmcblk0p8 is the risky part here. If a mount of p8 is still in
# place when fstools mounts /opt, mount_device() finds an existing mountpoint and
# skips /opt for the whole boot, leaving dockerd with an empty data-root. So:
#   - a cheap gate runs FIRST, before any mount, so an ordinary boot never probes
#     p8 at all (see the three conditions in do_restore_backup_enhanced());
#   - when p8 must be mounted it is mounted READ-ONLY, the payload is copied to
#     tmpfs immediately, and the unmount happens inside a subshell whose EXIT
#     trap guarantees it, with umount -l as the last resort, every outcome logged.
#
# Extraction never writes straight to / with `tar -k`. Measured on BusyBox
# v1.38.0: `tar -xzpkf` does not skip a pre-existing member, it aborts the WHOLE
# extraction at the first one and returns 1 - on a live rootfs that means almost
# nothing gets restored. -k also does not protect an existing directory's mode.
# So the member list is filtered down to the paths that are actually absent and
# only that list is handed to tar (-T); -k stays on the command line as a
# last-resort guard and is never triggered because every listed path is absent.
# Modes and owners are corrected afterwards from meta-enhanced.txt alone.
#
# Manual/test switches (both are checked before any mount):
#   /tmp/.restore-enhanced-force            - force the hook to run on the current
#                                             boot, even without an upgrade
#   <safe house>/backup-enhanced/.restore-enhanced-trigger
#                                           - same, but stored with the backup; only
#                                             visible when /opt is already mounted
#
# Safe-house cleanup stays OFF; see the RESTORE_ENHANCED_CLEAN block in
# restore_enhanced_apply().

RESTORE_ENHANCED_NAME="backup-enhanced"
RESTORE_ENHANCED_TAR="backup-enhanced.tar.gz"
RESTORE_ENHANCED_META="meta-enhanced.txt"
RESTORE_ENHANCED_LIST="filelist-enhanced.txt"
RESTORE_ENHANCED_TRIGGER=".restore-enhanced-trigger"
RESTORE_ENHANCED_FORCE="/tmp/.restore-enhanced-force"
RESTORE_ENHANCED_DEV="/dev/mmcblk0p8"
RESTORE_ENHANCED_MNT="/tmp/restore-enhanced-store"
RESTORE_ENHANCED_STAGE="/tmp/restore-enhanced.stage"
RESTORE_ENHANCED_BASE=""
[ -n "$RESTORE_ENHANCED_VERBOSE" ] || RESTORE_ENHANCED_VERBOSE=0

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

restore_enhanced_log() {
	logger -t restore-enhanced "$*" 2>/dev/null
	# In preinit there is no /dev/log yet (logd starts later), so logger writes
	# nowhere; fall back to kmsg there and stay quiet about it on a live system.
	if [ ! -e /dev/log ]; then
		echo "restore-enhanced: $*" > /dev/kmsg 2>/dev/null
	fi
	[ "$RESTORE_ENHANCED_VERBOSE" = "1" ] && echo "restore-enhanced: $*" >&2
	return 0
}

restore_enhanced_is_mount() {
	awk -v p="$1" '$2 == p { f = 1 } END { exit(f ? 0 : 1) }' /proc/mounts
}

restore_enhanced_mountpoint_of() {
	mount 2>/dev/null | awk -v d="$1" '
		{
			mp = ""
			for (i = 2; i <= NF; i++)
				if ($i == "on") { mp = $(i + 1); break }
			if ($1 == d && mp != "") { print mp; exit }
		}'
}

restore_enhanced_has_payload() {
	[ -n "$1" ] || return 1
	[ -f "$1/$RESTORE_ENHANCED_NAME/$RESTORE_ENHANCED_TAR" ]
}

# Unmount the temporary store, lazily if a busy mount refuses a plain umount.
# A leftover mount here would make fstools skip /opt for the whole boot, so this
# never gives up silently and always reports what it did.
restore_enhanced_unmount_store() {
	if restore_enhanced_is_mount "$RESTORE_ENHANCED_MNT"; then
		if umount "$RESTORE_ENHANCED_MNT" 2>/dev/null; then
			restore_enhanced_log "unmounted $RESTORE_ENHANCED_MNT"
		else
			restore_enhanced_log "umount busy, escalating to umount -l on $RESTORE_ENHANCED_MNT"
			if umount -l "$RESTORE_ENHANCED_MNT" 2>/dev/null; then
				restore_enhanced_log "lazy unmount of $RESTORE_ENHANCED_MNT done"
			else
				restore_enhanced_log "ERROR cannot unmount $RESTORE_ENHANCED_MNT; /opt may stay unmounted for this boot"
			fi
		fi
	fi
	# only complain when the directory really did exist and survived removal
	if [ -d "$RESTORE_ENHANCED_MNT" ]; then
		rmdir "$RESTORE_ENHANCED_MNT" 2>/dev/null ||
			restore_enhanced_log "note: $RESTORE_ENHANCED_MNT still present (not empty or busy)"
	fi
	return 0
}

# Mount /dev/mmcblk0p8 read-only, copy the payload to tmpfs, unmount again.
# The whole sequence runs in a subshell so the EXIT trap cannot leak into the
# preinit shell and cannot be forgotten on an error path.
restore_enhanced_fetch_selfmount() {
	local rc=1

	rm -rf "$RESTORE_ENHANCED_STAGE"
	mkdir -p "$RESTORE_ENHANCED_STAGE" 2>/dev/null || return 1

	(
		trap restore_enhanced_unmount_store EXIT INT TERM HUP

		modprobe btrfs 2>/dev/null
		mkdir -p "$RESTORE_ENHANCED_MNT" 2>/dev/null || exit 1
		# read-only on purpose: nothing here needs to write to the safe house,
		# and a stray rw mount would hide /opt from fstools for this boot.
		mount -o ro "$RESTORE_ENHANCED_DEV" "$RESTORE_ENHANCED_MNT" 2>/dev/null || exit 1
		restore_enhanced_log "mounted $RESTORE_ENHANCED_DEV read-only at $RESTORE_ENHANCED_MNT for the payload copy"

		src="$RESTORE_ENHANCED_MNT/$RESTORE_ENHANCED_NAME"
		[ -f "$src/$RESTORE_ENHANCED_TAR" ] || exit 1
		cp "$src/$RESTORE_ENHANCED_TAR" "$RESTORE_ENHANCED_STAGE/" 2>/dev/null || exit 1
		cp "$src/$RESTORE_ENHANCED_META" "$RESTORE_ENHANCED_STAGE/" 2>/dev/null
		cp "$src/$RESTORE_ENHANCED_LIST" "$RESTORE_ENHANCED_STAGE/" 2>/dev/null
		exit 0
	)
	rc=$?

	if [ "$rc" -ne 0 ]; then
		rm -rf "$RESTORE_ENHANCED_STAGE"
		return 1
	fi
	return 0
}

# Probe chain: /boot -> /recovery -> mountpoint of /dev/mmcblk0p1 -> /opt ->
# mount /dev/mmcblk0p8 ourselves. Same hardware reality as in
# backup-enhanced.sh: the first three never match on this board.
# Sets RESTORE_ENHANCED_BASE to the directory holding the three files.
restore_enhanced_locate() {
	local cand

	for cand in /boot /recovery; do
		if restore_enhanced_is_mount "$cand" && restore_enhanced_has_payload "$cand"; then
			RESTORE_ENHANCED_BASE="$cand/$RESTORE_ENHANCED_NAME"
			return 0
		fi
	done

	cand=$(restore_enhanced_mountpoint_of /dev/mmcblk0p1)
	if restore_enhanced_is_mount "$cand" && restore_enhanced_has_payload "$cand"; then
		RESTORE_ENHANCED_BASE="$cand/$RESTORE_ENHANCED_NAME"
		return 0
	fi

	if restore_enhanced_is_mount /opt && restore_enhanced_has_payload /opt; then
		RESTORE_ENHANCED_BASE="/opt/$RESTORE_ENHANCED_NAME"
		return 0
	fi

	if [ -b "$RESTORE_ENHANCED_DEV" ]; then
		if restore_enhanced_fetch_selfmount; then
			RESTORE_ENHANCED_BASE="$RESTORE_ENHANCED_STAGE"
			return 0
		fi
	fi

	return 1
}

# drwxr-xr-x -> u=rwx,g=rx,o=rx (symbolic triplets; chmod u=rwx,go=rx verified on
# this BusyBox, and empty clauses such as g= are accepted). Measured: a '-'
# inside a clause silently truncates the rest of that clause (u=rwx,g=r-x,o=r-x
# yields -rwxr--r--), so the '-' placeholders are stripped, not passed through.
# setuid/setgid/sticky cannot be expressed this way and are reported instead of
# being silently dropped.
restore_enhanced_symbolic() {
	local m="$1"

	[ ${#m} -eq 10 ] || return 1
	case "$m" in
	*[sStT]*) return 1 ;;
	esac
	printf '%s\n' "$m" | awk '{
		b = substr($0, 2)
		u = substr(b, 1, 3)
		g = substr(b, 4, 3)
		o = substr(b, 7, 3)
		gsub(/-/, "", u)
		gsub(/-/, "", g)
		gsub(/-/, "", o)
		printf "u=%s,g=%s,o=%s\n", u, g, o
	}'
}

# current "mode uid gid" of a path; `ls -ldn` is the only source available
# (no stat(1) on this image). The positional parameters are re-set on purpose,
# which is why callers always capture the result with $( ) .
restore_enhanced_stat() {
	local rec

	rec=$(ls -ldn "$1" 2>/dev/null) || return 1
	[ -n "$rec" ] || return 1
	# shellcheck disable=SC2086  # 故意分词：把 ls -ldn 的输出拆成 mode/links/uid/gid/size/... 字段
	set -- $rec
	[ -n "$1" ] || return 1
	echo "$1 $3 $4"
}

# ---------------------------------------------------------------------------
# the work: extract what is missing, then correct mode/owner
# ---------------------------------------------------------------------------

restore_enhanced_apply() {
	local base="$1"
	local archive="$base/$RESTORE_ENHANCED_TAR"
	local meta="$base/$RESTORE_ENHANCED_META"
	local errfile="/tmp/restore-enhanced.$$.err"
	local members="/tmp/restore-enhanced.$$.members"
	local todo="/tmp/restore-enhanced.$$.todo"
	local mode uid gid path cur cur_mode cur_uid cur_gid target
	local member_count todo_count skipped restored
	local changed_mode=0 changed_owner=0 consistent=0 missing=0 symlink=0 badmode=0
	local logged=0 skiplog=20
	# Bounded skip logging: the syslog ring cannot hold a line per path, so only
	# the first 20 consistent entries are logged unless RESTORE_ENHANCED_VERBOSE=1
	[ "$RESTORE_ENHANCED_VERBOSE" = "1" ] && skiplog=1000000

	restore_enhanced_log "start: base=$base"

	# members: what the archive holds. Names were produced with `tar -C / -T rel`,
	# so they carry no "./" prefix and match `tar -tzf` output exactly (verified).
	if ! tar -tzf "$archive" > "$members" 2> "$errfile"; then
		restore_enhanced_log "ERROR cannot read $archive"
		rm -f "$errfile" "$members"
		return 0
	fi

	: > "$todo"
	while read -r path; do
		[ -n "$path" ] || continue
		[ -e "/$path" ] && continue
		[ -L "/$path" ] && continue
		printf '%s\n' "$path" >> "$todo"
	done < "$members"
	# never feed an empty expansion to $(( )): BusyBox sh aborts the whole shell
	# on an arithmetic syntax error, which would hang the boot.
	member_count=$(wc -l < "$members")
	[ -n "$member_count" ] || member_count=0
	todo_count=$(wc -l < "$todo")
	[ -n "$todo_count" ] || todo_count=0
	skipped=$((member_count - todo_count))
	restored=$todo_count

	if [ "$todo_count" -gt 0 ]; then
		if ! tar -xzpkf "$archive" -C / -T "$todo" 2> "$errfile"; then
			restore_enhanced_log "ERROR tar extract failed on $archive; see $errfile"
			rm -f "$errfile" "$members" "$todo"
			return 0
		fi
	fi
	rm -f "$errfile" "$members" "$todo"
	restore_enhanced_log "extract done: kept $skipped existing paths untouched, restored $restored missing ones"

	if [ ! -f "$meta" ]; then
		restore_enhanced_log "no $RESTORE_ENHANCED_META; metadata fix skipped"
		return 0
	fi

	while read -r mode uid gid path; do
		[ -n "$path" ] || continue
		case "$mode" in
		l*) symlink=$((symlink + 1)); continue ;;
		esac
		if [ ! -e "$path" ]; then
			missing=$((missing + 1))
			continue
		fi
		cur=$(restore_enhanced_stat "$path") || {
			missing=$((missing + 1))
			continue
		}
		cur_mode=${cur%% *}
		cur=${cur#* }
		cur_uid=${cur%% *}
		cur_gid=${cur#* }

		target=""
		if [ "$cur_mode" != "$mode" ]; then
			target=$(restore_enhanced_symbolic "$mode")
			if [ -z "$target" ]; then
				badmode=$((badmode + 1))
				restore_enhanced_log "WARN $path: mode $mode not expressible symbolically; skipped"
			else
				if chmod "$target" "$path" 2>/dev/null; then
					changed_mode=$((changed_mode + 1))
					restore_enhanced_log "fixed mode $path: $cur_mode -> $mode (chmod $target)"
				fi
			fi
		fi
		if [ "$cur_uid:$cur_gid" != "$uid:$gid" ]; then
			if chown "$uid:$gid" "$path" 2>/dev/null; then
				changed_owner=$((changed_owner + 1))
				restore_enhanced_log "fixed owner $path: $cur_uid:$cur_gid -> $uid:$gid"
			fi
		fi
		if [ "$cur_mode" = "$mode" ] && [ "$cur_uid:$cur_gid" = "$uid:$gid" ]; then
			consistent=$((consistent + 1))
			if [ "$logged" -lt "$skiplog" ]; then
				logged=$((logged + 1))
				restore_enhanced_log "consistent, skipped: $path ($mode $uid:$gid)"
			fi
		fi
	done < "$meta"

	restore_enhanced_log "done: mode fixed=$changed_mode owner fixed=$changed_owner consistent=$consistent missing=$missing symlinks=$symlink unsupported=$badmode"

	# RESTORE_ENHANCED_CLEAN (off by default): the archive is kept so the restore
	# can be repeated on a later boot. To drop it after a successful run, uncomment
	#   restore_enhanced_log "cleanup enabled: removing $base"
	#   rm -rf "$base"
	# (only meaningful for an already mounted store; a self-mounted payload is a
	# read-only copy in tmpfs that disappears with the next reboot anyway).
	return 0
}

# ---------------------------------------------------------------------------
# the hook itself
# ---------------------------------------------------------------------------

do_restore_backup_enhanced() {
	local reason=""

	# 1. Cheap gate, before any mount. During preinit the safe house lives on a
	#    partition that is not mounted yet, so probing it costs a mount/unmount
	#    round trip - and an ordinary boot has nothing to restore. Run only when:
	#      - /sysupgrade.tgz or /tmp/sysupgrade.tar exists (the official restore
	#        just ran; 80_mount_root recognises both names), or
	#      - /tmp/.restore-enhanced-force exists (explicit manual test switch), or
	#      - /opt is already mounted and carries the trigger marker (a normal boot
	#        never satisfies this: /opt is mounted long after preinit).
	if [ -f /sysupgrade.tgz ] || [ -f /tmp/sysupgrade.tar ]; then
		reason="official restore pending"
	elif [ -f "$RESTORE_ENHANCED_FORCE" ]; then
		reason="forced by $RESTORE_ENHANCED_FORCE"
	elif restore_enhanced_is_mount /opt &&
		[ -f "/opt/$RESTORE_ENHANCED_NAME/$RESTORE_ENHANCED_TRIGGER" ]; then
		reason="trigger marker in the mounted safe house"
	fi
	if [ -z "$reason" ]; then
		restore_enhanced_log "idle: not an upgrade boot and no manual trigger; safe house not probed"
		return 0
	fi
	restore_enhanced_log "starting: $reason"

	# 2. Only now locate the safe house (may mount p8 read-only and copy off it).
	if ! restore_enhanced_locate; then
		restore_enhanced_log "no safe house holding $RESTORE_ENHANCED_TAR; nothing restored"
		restore_enhanced_unmount_store
		rm -rf "$RESTORE_ENHANCED_STAGE"
		return 0
	fi

	# 3. Restore from the located payload.
	restore_enhanced_apply "$RESTORE_ENHANCED_BASE"

	# 4. Always leave p8 alone again: a leftover mount would hide /opt from fstools.
	restore_enhanced_unmount_store
	case "$RESTORE_ENHANCED_BASE" in
	"$RESTORE_ENHANCED_STAGE"*) rm -rf "$RESTORE_ENHANCED_STAGE" ;;
	esac
	RESTORE_ENHANCED_BASE=""
	return 0
}

boot_hook_add preinit_main do_restore_backup_enhanced
