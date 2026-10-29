#!/bin/sh
# shellcheck shell=busybox
# Enhanced backup for ImmortalWrt (Banana Pi BPI-R4) - sourced by /sbin/sysupgrade.
#
# /sbin/sysupgrade runs `include /lib/upgrade`, and include() is
#   for file in $(ls $1/*.sh); do . $file; done
# so this file is sourced into the running sysupgrade shell. Two things must
# therefore happen at source time:
#   1. stay completely inert when the caller only wants the backup list
#      (CONF_BACKUP_LIST=1) - otherwise our own `sysupgrade --list-backup`
#      call would re-source this file and recurse forever;
#   2. append the worker function to $sysupgrade_init_conffiles so that
#      create_backup_archive() -> run_hooks "$CONFFILES" ... actually calls it.
#
# Hardware reality on this board (measured on SNAPSHOT, do not "fix"):
#   - /dev/mmcblk0p1 is a raw eMMC boot blob (first sector 'SDMMC_BOOT',
#     GPT name bl2); mounting it fails with EINVAL.
#   - /boot and /recovery do not exist at all.
#   - The overlay (fitrw, f2fs) shares /dev/mmcblk0p7 with the squashfs rootfs,
#     so both are rewritten by sysupgrade - never usable as a safe house.
#   - The only partition that survives an upgrade and is writable is
#     /dev/mmcblk0p8 (btrfs, normally mounted at /opt).
# The probe chain below keeps the requested order for boards that really do
# have /boot or /recovery, but on the BPI-R4 the first three candidates always
# fail and the /opt fallback is the branch that makes this script usable.

BACKUP_ENHANCED_NAME="backup-enhanced"
BACKUP_ENHANCED_TAR="backup-enhanced.tar.gz"
BACKUP_ENHANCED_LIST="filelist-enhanced.txt"
BACKUP_ENHANCED_META="meta-enhanced.txt"

# ---------------------------------------------------------------------------
# source-time behaviour
# ---------------------------------------------------------------------------

if [ "$CONF_BACKUP_LIST" = "1" ] || [ "$BACKUP_ENHANCED_LISTING" = "1" ]; then
	return 0
fi

# sysupgrade sets this before `include /lib/upgrade`; the fallback covers
# a manual `. /lib/upgrade/backup-enhanced.sh` and the -b style invocations.
if [ -z "$sysupgrade_init_conffiles" ]; then
	sysupgrade_init_conffiles="build_list_of_backup_config_files"
fi

case " $sysupgrade_init_conffiles " in
*" backup_enhanced_hook "*) ;;
*) sysupgrade_init_conffiles="$sysupgrade_init_conffiles backup_enhanced_hook" ;;
esac

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

backup_enhanced_log() {
	logger -t backup-enhanced "$*" 2>/dev/null
	return 0
}

backup_enhanced_is_mount() {
	awk -v p="$1" '$2 == p { f = 1 } END { exit(f ? 0 : 1) }' /proc/mounts
}

# mountpoint currently holding a given device, parsed from `mount` output.
backup_enhanced_mountpoint_of() {
	mount 2>/dev/null | awk -v d="$1" '
		{
			mp = ""
			for (i = 2; i <= NF; i++)
				if ($i == "on") { mp = $(i + 1); break }
			if ($1 == d && mp != "") { print mp; exit }
		}'
}

# A candidate is usable when it is a real, already mounted, writable mount
# point; the safe house directory is created as part of the test.
backup_enhanced_store_usable() {
	[ -n "$1" ] || return 1
	[ -d "$1" ] || return 1
	backup_enhanced_is_mount "$1" || return 1
	mkdir -p "$1/$BACKUP_ENHANCED_NAME" 2>/dev/null || return 1
	[ -w "$1/$BACKUP_ENHANCED_NAME" ] || return 1
	return 0
}

# Probe chain: /boot -> /recovery -> mountpoint of /dev/mmcblk0p1 -> /opt.
backup_enhanced_find_store() {
	local cand

	for cand in /boot /recovery; do
		if backup_enhanced_store_usable "$cand"; then
			echo "$cand"
			return 0
		fi
	done

	cand=$(backup_enhanced_mountpoint_of /dev/mmcblk0p1)
	if backup_enhanced_store_usable "$cand"; then
		echo "$cand"
		return 0
	fi

	if backup_enhanced_store_usable /opt; then
		echo /opt
		return 0
	fi

	return 1
}

# Walk the manifest once: record mode/uid/gid for every entry (no stat(1) and
# no `find -printf` on BusyBox, so `ls -ldn` is the only source of both the
# symbolic mode and the numeric owner) and sum the apparent sizes, which is the
# conservative upper bound used for the free-space pre-check.
# Writes meta to $2, prints the byte total on stdout.
backup_enhanced_collect_meta() {
	local manifest="$1"
	local line rec total=0

	# note: "$1" must be copied first, the loops below reset the positional
	# parameters via `set --`.
	{
		while read -r line; do
			[ -n "$line" ] || continue
			rec=$(ls -ldn "$line" 2>/dev/null) || continue
			# shellcheck disable=SC2086  # 故意分词：把 ls -ldn 的输出拆成 mode/links/uid/gid/size/... 字段
			set -- $rec
			[ -n "$5" ] || continue
			case "$5" in
			*[!0-9]*) ;;
			*) total=$((total + $5)) ;;
			esac
			printf '%s %s %s %s\n' "$1" "$3" "$4" "$line"
		done < "$manifest"

		# sysupgrade's manifest lists files only, so directory modes would be
		# lost. Record every parent directory as well (mode/owner of /etc/config
		# and friends is restored from here); sizes are not counted for them.
		sed 's,/[^/]*$,,' "$manifest" | sed 's,^$,/,' | sort -u | {
			while read -r line; do
				[ -n "$line" ] || continue
				[ "$line" = "/" ] && continue
				rec=$(ls -ldn "$line" 2>/dev/null) || continue
				# shellcheck disable=SC2086  # 故意分词：把 ls -ldn 的输出拆成 mode/links/uid/gid/size/... 字段
				set -- $rec
				[ -n "$1" ] || continue
				printf '%s %s %s %s\n' "$1" "$3" "$4" "$line"
			done
		}
	} > "$2"

	echo "$total"
}

backup_enhanced_free_bytes() {
	df -k "$1" 2>/dev/null | awk 'NR == 2 { print $4 * 1024; exit }'
}

# ---------------------------------------------------------------------------
# the hook itself
# ---------------------------------------------------------------------------

backup_enhanced_hook() {
	local conf_list="$1"
	local store base work part final raw avail need out

	backup_enhanced_log "start (conffiles=$conf_list)"

	store=$(backup_enhanced_find_store)
	if [ -z "$store" ]; then
		backup_enhanced_log "no writable safe house (/boot, /recovery, mmcblk0p1, /opt all unusable); nothing written"
		return 0
	fi
	base="$store/$BACKUP_ENHANCED_NAME"
	backup_enhanced_log "safe house: $base (probe chain; on BPI-R4 this normally lands on /opt)"

	work="/tmp/backup-enhanced.$$"
	rm -rf "$work"
	if ! mkdir -p "$work"; then
		backup_enhanced_log "cannot create work dir $work; nothing written"
		return 0
	fi

	# The nested sysupgrade must not re-source this file: both guards above
	# fire for the child (it sets CONF_BACKUP_LIST=1 itself, and we export
	# BACKUP_ENHANCED_LISTING=1 for good measure).
	BACKUP_ENHANCED_LISTING=1 sysupgrade --list-backup > "$work/list" 2> "$work/list.err"
	if [ ! -s "$work/list" ]; then
		backup_enhanced_log "sysupgrade --list-backup produced no files; nothing written"
		sed -n '1,3p' "$work/list.err" > /dev/kmsg 2>/dev/null
		rm -rf "$work"
		return 0
	fi
	backup_enhanced_log "manifest: $(wc -l < "$work/list") entries"

	raw=$(backup_enhanced_collect_meta "$work/list" "$work/meta")
	backup_enhanced_log "metadata: $(wc -l < "$work/meta") entries, apparent size ${raw} bytes"

	# Free-space pre-check: compression only shrinks, so the uncompressed total
	# plus a small margin is a safe (if pessimistic) requirement. Bail out before
	# creating anything so no half-written archive is ever left behind.
	avail=$(backup_enhanced_free_bytes "$store")
	case "$avail" in
	''|*[!0-9]*)
		backup_enhanced_log "WARN cannot read free space on $store; continuing without pre-check"
		;;
	*)
		need=$((raw + 8 * 1024 * 1024))
		if [ "$avail" -lt "$need" ]; then
			backup_enhanced_log "ABORT not enough space on $store: need $need bytes, available $avail bytes"
			rm -rf "$work"
			return 0
		fi
		backup_enhanced_log "space ok: need $need <= available $avail bytes"
		;;
	esac

	cp "$work/list" "$base/$BACKUP_ENHANCED_LIST" || {
		backup_enhanced_log "cannot write $base/$BACKUP_ENHANCED_LIST; abort"
		rm -rf "$work"
		return 0
	}
	cp "$work/meta" "$base/$BACKUP_ENHANCED_META" || {
		backup_enhanced_log "cannot write $base/$BACKUP_ENHANCED_META; abort"
		rm -rf "$work"
		return 0
	}

	# tar works from / with relative names, exactly like sysupgrade itself does.
	sed 's,^/,,' "$work/list" > "$work/rel"
	{
		printf '%s\n' "${base#/}"
		printf '%s\n' "${work#/}"
	} > "$work/excl"

	part="$base/$BACKUP_ENHANCED_TAR.part"
	final="$base/$BACKUP_ENHANCED_TAR"
	rm -f "$part"
	backup_enhanced_log "packing $(wc -l < "$work/rel") paths"
	if ! tar -czpf "$part" -C / -T "$work/rel" -X "$work/excl" 2> "$work/tar.err"; then
		backup_enhanced_log "ABORT tar failed; partial archive removed"
		sed -n '1,5p' "$work/tar.err" > /dev/kmsg 2>/dev/null
		rm -f "$part"
		rm -rf "$work"
		return 0
	fi
	if [ ! -s "$part" ]; then
		backup_enhanced_log "ABORT tar produced an empty archive; removed"
		rm -f "$part"
		rm -rf "$work"
		return 0
	fi
	mv "$part" "$final" || {
		backup_enhanced_log "ABORT cannot move archive into place"
		rm -f "$part"
		rm -rf "$work"
		return 0
	}

	out=$(ls -l "$final" "$base/$BACKUP_ENHANCED_LIST" "$base/$BACKUP_ENHANCED_META" 2>/dev/null)
	backup_enhanced_log "done: $final"
	# the artifact listing goes to kmsg only where logger has no sink (/dev/log)
	if [ ! -e /dev/log ] && [ -n "$out" ]; then
		printf '%s\n' "$out" > /dev/kmsg 2>/dev/null
	fi
	rm -rf "$work"
	return 0
}
