#!/bin/sh
# shellcheck shell=busybox
# Enhanced backup for ImmortalWrt (Banana Pi BPI-R4) - sourced by /sbin/sysupgrade.
#
# /sbin/sysupgrade runs `include /lib/upgrade`, and include() is
#   for file in $(ls $1/*.sh); do . $file; done
# so this file is sourced into the running sysupgrade shell. Two things must
# therefore happen at source time:
#   1. stay completely inert when the caller only wants the backup list
#      (CONF_BACKUP_LIST=1) - that path already runs the hooks and prints the
#      list, and registering ours there would only duplicate the work;
#   2. append the worker function to $sysupgrade_init_conffiles so that
#      create_backup_archive() -> run_hooks "$CONFFILES" ... actually calls it.
#
# Hardware reality on this board (measured on SNAPSHOT, do not "fix"):
#   - /dev/mmcblk0p1 is a raw eMMC boot blob (first sector 'SDMMC_BOOT',
#     GPT name bl2); mounting it fails with EINVAL.
#   - /boot and /recovery do not exist at all.
#   - The overlay (fitrw, f2fs) shares /dev/mmcblk0p7 with the squashfs rootfs,
#     so both are rewritten by sysupgrade - never usable as a safe house.
#   - /dev/mmcblk0p8 (btrfs, normally at /opt) does survive, but it is NOT
#     mounted during preinit (fstools mounts it from a START=11 init script) and
#     it depends on the btrfs module being loaded. That makes it a second-rate
#     carrier: see "why the payload rides inside CONF_TAR" below.
#
# Why the payload rides inside CONF_TAR
# -------------------------------------
# sysupgrade keeps its config backup in /tmp/sysupgrade.tgz, i.e. tmpfs. It only
# survives the reboot because procd hands that one file to stage2, which dd's it
# onto the eMMC:
#   emmc_copy_config(): dd if=$UPGRADE_BACKUP of=$EMMC_KERN_DEV bs=512 seek=$EMMC_KERNEL_BLOCKS
# On this board the image is a FIT, so emmc_upgrade_fit() sets EMMC_KERNEL_BLOCKS
# and the backup lands right after the FIT image inside p7 - outside every
# filesystem. initramfs reads it back into /sysupgrade.tgz on the next boot.
#
# Nothing else crosses the reboot: a file merely written to /tmp disappears, and
# a second file next to CONF_TAR would never be dd'd because emmc_copy_config
# only knows $UPGRADE_BACKUP. The only carrier that both survives and needs no
# extra mount is CONF_TAR itself.
#
# The payload therefore rides *inside* CONF_TAR as a nested tarball rather than
# as loose paths. Loose paths would be extracted by the official
# `tar xzf /sysupgrade.tgz` in preinit/80_mount_root, which has no -k and would
# silently overwrite live files - the opposite of the "only fill in what is
# missing" contract. A nested tarball extracts to a single path under /tmp and
# touches nothing until our own hook unwraps it, after the official restore.
#
# /opt is still used, but only as a redundant human-inspectable copy; the
# restore path never depends on it.

BACKUP_ENHANCED_NAME="backup-enhanced"
BACKUP_ENHANCED_TAR="backup-enhanced.tar.gz"
BACKUP_ENHANCED_LIST="filelist-enhanced.txt"
BACKUP_ENHANCED_META="meta-enhanced.txt"
# Nested payload as it appears inside CONF_TAR (relative to /, no leading slash).
BACKUP_ENHANCED_PAYLOAD_DIR="tmp/backup-enhanced"

# ---------------------------------------------------------------------------
# source-time behaviour
# ---------------------------------------------------------------------------

if [ "$CONF_BACKUP_LIST" = "1" ]; then
	return 0
fi

# sysupgrade sets this before `include /lib/upgrade`; the fallback covers
# a manual `. /lib/upgrade/backup-enhanced.sh` and the -b style invocations.
# Keep the official list builder first: the hook reads the manifest it produces.
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

# Write (to $2) the paths whose content the payload has to carry.
#
# The set to protect is NOT the manifest: the manifest is whatever sysupgrade
# decided to back up, so "paths missing from CONF_TAR" would trivially be empty
# and the payload would never carry anything. That tautology is exactly how
# /home was lost in the field: `sysupgrade -c` switches the list builder to
# build_list_of_backup_overlay_files, which only walks /overlay/upper/etc, so
# the /home and /root entries in /etc/sysupgrade.conf never entered the manifest
# at all - and a manifest-derived "uncovered" set cannot see what is not there.
#
# The protection set therefore comes from /etc/sysupgrade.conf (the user's
# declared intent) plus /etc/sysupgrade.conf.d-style drop-ins are out of scope.
# Entries the manifest already covers are left out so CONF_TAR does not grow
# with a second copy of the same bytes.
backup_enhanced_collect_uncovered() {
	local conf="$1" out="$2" manifest="$3"
	local entry rel probe found

	: > "$out"
	[ -r "$conf" ] || return 0
	while read -r entry; do
		case "$entry" in
		''|'#'*) continue ;;
		esac
		rel="${entry#/}"
		[ -n "$rel" ] || continue
		# Covered already when the manifest lists it, or lists something above it.
		found=0
		probe="$rel"
		while [ -n "$probe" ]; do
			if grep -qxF "/$probe" "$manifest" 2>/dev/null; then
				found=1
				break
			fi
			case "$probe" in
			*/*) probe="${probe%/*}" ;;
			*) break ;;
			esac
		done
		# Also covered when the manifest lists something below it (a directory
		# whose files are all present does not need to be re-packed).
		if [ "$found" = 0 ] && grep -qF "/$rel/" "$manifest" 2>/dev/null; then
			found=1
		fi
		# Skip entries that do not exist on this system at all (/etc/sysupgrade.conf
		# is a template: it lists /usr/local/bin even where that directory was
		# never created). tar would abort with "No such file or directory".
		if [ "$found" = 0 ] && [ ! -e "/$rel" ] && [ ! -L "/$rel" ]; then
			continue
		fi
		[ "$found" = 1 ] || printf '%s\n' "$rel" >> "$out"
	done < "$conf"
	return 0
}

# Append one absolute path to the manifest the parent is about to tar.
# The parent already ran `sed -i 's,^/,,'`-compatible processing only *after*
# run_hooks returns (/sbin/sysupgrade:285), so entries must be written with a
# leading slash exactly like the official builder does.
backup_enhanced_append_manifest() {
	local manifest="$1" entry="$2"

	[ -n "$manifest" ] && [ -n "$entry" ] || return 1
	# Already present (idempotent source order, manual re-runs)?
	grep -qxF "$entry" "$manifest" 2>/dev/null && return 0
	printf '%s\n' "$entry" >> "$manifest"
}

# ---------------------------------------------------------------------------
# the hook itself
# ---------------------------------------------------------------------------

backup_enhanced_hook() {
	local conf_list="$1"
	local store base work raw avail need out stage payload
	local stage_have=0 store_have=0

	backup_enhanced_log "start (conffiles=$conf_list)"

	if [ ! -s "$conf_list" ]; then
		backup_enhanced_log "empty manifest ($conf_list); nothing written"
		return 0
	fi

	work="/tmp/backup-enhanced.$$"
	rm -rf "$work"
	if ! mkdir -p "$work"; then
		backup_enhanced_log "cannot create work dir $work; nothing written"
		return 0
	fi

	# Take the manifest from $1: run_hooks already built it and handed it over.
	#   run_hooks() { local arg="$1"; shift; for func in "$@"; do eval "$func $arg"; done; }
	# The official build_list_of_backup_config_files is registered first, so the
	# file is complete by the time this hook runs.
	#
	# Never spawn `sysupgrade --list-backup` from here. That child inherits the
	# exported CONFFILES=/tmp/sysupgrade.conffiles (/sbin/sysupgrade:37) and its
	# list-backup branch ends with `rm -f "$CONFFILES"` (/sbin/sysupgrade:345).
	# A child started inside this hook therefore deletes the *parent's* manifest;
	# the parent's next steps -- `sed -i` then `tar c -T "$CONFFILES"` -- then fail
	# on the missing file, create_backup_archive() returns non-zero, and sysupgrade
	# exits via `|| exit` before writing anything. Net effect: the upgrade aborts
	# silently right after "Saving config files...".
	cp "$conf_list" "$work/list" || {
		backup_enhanced_log "cannot read manifest $conf_list; nothing written"
		rm -rf "$work"
		return 0
	}
	backup_enhanced_log "manifest: $(wc -l < "$work/list") entries"

	raw=$(backup_enhanced_collect_meta "$work/list" "$work/meta")
	backup_enhanced_log "metadata: $(wc -l < "$work/meta") entries, apparent size ${raw} bytes"

	# ---- build the nested payload -------------------------------------------
	# The payload directory lives in the list as tmp/... so it is tarred as part
	# of CONF_TAR. Wipe any stale copy first: a leftover from an earlier run
	# would be tarred instead of the fresh one.
	stage="/$BACKUP_ENHANCED_PAYLOAD_DIR"
	rm -rf "$stage"
	if ! mkdir -p "$stage"; then
		backup_enhanced_log "ABORT cannot create payload dir $stage; nothing written"
		rm -rf "$work"
		return 0
	fi
	stage_have=1

	# What the payload must carry: the paths the user asked to keep (from
	# /etc/sysupgrade.conf) minus whatever the manifest already covers. Deriving
	# it from the manifest instead would be a tautology - see the comment on
	# backup_enhanced_collect_uncovered() for the field failure that motivated it.
	backup_enhanced_collect_uncovered /etc/sysupgrade.conf "$work/uncovered" "$conf_list"
	if [ -s "$work/uncovered" ]; then
		backup_enhanced_log "payload carries $(wc -l < "$work/uncovered") declared paths the manifest omits"
		cat "$work/uncovered" > "$work/pay-list"
	else
		backup_enhanced_log "payload carries metadata only (manifest already covers every declared path)"
	fi

	# The metadata files are packed INSIDE the payload (not beside it), because
	# BusyBox tar refuses to create an empty archive ("tar: empty archive", rc=1)
	# - with nothing to pack, the metadata itself is what makes the payload
	# non-empty, and the restore side reads both files back out of it.
	if ! cp "$work/meta" "$stage/$BACKUP_ENHANCED_META" 2>/dev/null; then
		backup_enhanced_log "ABORT cannot write $stage/$BACKUP_ENHANCED_META"
		rm -rf "$work"; rm -rf "$stage"
		return 0
	fi
	if ! cp "$work/list" "$stage/$BACKUP_ENHANCED_LIST" 2>/dev/null; then
		backup_enhanced_log "ABORT cannot write $stage/$BACKUP_ENHANCED_LIST"
		rm -rf "$work"; rm -rf "$stage"
		return 0
	fi
	printf '%s\n' "${stage#/}/$BACKUP_ENHANCED_META" >> "$work/pay-list"
	printf '%s\n' "${stage#/}/$BACKUP_ENHANCED_LIST" >> "$work/pay-list"

	# Final filter: tar aborts the whole run on a member it cannot open ("tar:
	# usr/local/bin: No such file or directory"), and BusyBox reports that through
	# stderr while still returning 0, so the exit status alone would not catch it.
	# Drop anything that vanished or is unreadable between the checks above.
	: > "$work/pay-final"
	while read -r rel; do
		[ -n "$rel" ] || continue
		if [ -e "/$rel" ] || [ -L "/$rel" ]; then
			printf '%s\n' "$rel" >> "$work/pay-final"
		else
			backup_enhanced_log "skip vanished path: /$rel"
		fi
	done < "$work/pay-list"

	# Exclude only the payload FILE being written (it is incomplete right now) and
	# the scratch dir. The stage directory itself must stay packable: the metadata
	# lives inside it, so excluding "<stage>" would also drop every member below.
	{
		printf '%s\n' "${stage#/}/$BACKUP_ENHANCED_TAR"
		printf '%s\n' "${stage#/}/$BACKUP_ENHANCED_TAR.part"
		printf '%s\n' "${work#/}"
	} > "$work/excl"

	payload="$stage/$BACKUP_ENHANCED_TAR"
	rm -f "$payload.part"
	backup_enhanced_log "packing payload ($(wc -l < "$work/pay-final") members)"
	if ! tar -czpf "$payload.part" -C / -T "$work/pay-final" -X "$work/excl" 2> "$work/tar.err"; then
		backup_enhanced_log "ABORT payload tar failed; nothing written"
		sed -n '1,5p' "$work/tar.err" > /dev/kmsg 2>/dev/null
		rm -rf "$work"; rm -rf "$stage"
		return 0
	fi
	if [ -s "$work/tar.err" ]; then
		# BusyBox tar can still emit warnings; keep them visible but do not fail.
		backup_enhanced_log "payload tar warnings: $(sed -n '1p' "$work/tar.err")"
	fi
	if [ ! -s "$payload.part" ]; then
		backup_enhanced_log "ABORT payload tar produced an empty archive; nothing written"
		rm -rf "$work"; rm -rf "$stage"
		return 0
	fi
	mv "$payload.part" "$payload" || {
		backup_enhanced_log "ABORT cannot move payload into place"
		rm -rf "$work"; rm -rf "$stage"
		return 0
	}
	backup_enhanced_log "payload: $payload ($(wc -c < "$payload" 2>/dev/null | tr -d ' ') bytes)"

	# ---- hand it to the parent ----------------------------------------------
	# This is the step that makes the payload survive the reboot: the parent tars
	# everything listed in $conf_list into CONF_TAR, and CONF_TAR is the one file
	# procd dd's onto the eMMC.
	backup_enhanced_append_manifest "$conf_list" "$stage" || {
		backup_enhanced_log "ABORT cannot append $stage to $conf_list"
		rm -rf "$work"; rm -rf "$stage"
		return 0
	}
	# The tar directory members are not guaranteed to appear in the manifest, and
	# the payload file itself must be listed too (an explicit member list does not
	# recurse).
	backup_enhanced_append_manifest "$conf_list" "$payload" 2>/dev/null
	backup_enhanced_log "appended $stage to the official manifest (rides inside CONF_TAR)"

	# ---- optional redundant copy in the safe house --------------------------
	# Purely for humans and for boards where the payload is wanted on disk too.
	# Restore never depends on it, so every failure here is a warning, not an abort.
	store=$(backup_enhanced_find_store)
	if [ -n "$store" ]; then
		base="$store/$BACKUP_ENHANCED_NAME"
		if [ -w "$base" ]; then
			avail=$(backup_enhanced_free_bytes "$store")
			case "$avail" in
			''|*[!0-9]*) need=0 ;;
			*) need=$((raw + 8 * 1024 * 1024)) ;;
			esac
			if [ "$need" -eq 0 ] || [ "$avail" -ge "$need" ]; then
				if cp "$payload" "$base/$BACKUP_ENHANCED_TAR" 2>/dev/null &&
					cp "$work/meta" "$base/$BACKUP_ENHANCED_META" 2>/dev/null &&
					cp "$work/list" "$base/$BACKUP_ENHANCED_LIST" 2>/dev/null; then
					store_have=1
					backup_enhanced_log "redundant copy updated: $base"
				else
					backup_enhanced_log "WARN redundant copy failed on $base (payload in CONF_TAR is unaffected)"
				fi
			else
				backup_enhanced_log "WARN skipping redundant copy on $store: need $need > available $avail"
			fi
		else
			backup_enhanced_log "note: $base not writable; payload still rides inside CONF_TAR"
		fi
	else
		backup_enhanced_log "note: no safe house probe hit; payload still rides inside CONF_TAR"
	fi

	out=$(ls -l "$payload" 2>/dev/null)
	backup_enhanced_log "done: payload=$( [ "$stage_have" = 1 ] && echo "$payload" ) redundant_copy=$store_have"
	# the artifact listing goes to kmsg only where logger has no sink (/dev/log)
	if [ ! -e /dev/log ] && [ -n "$out" ]; then
		printf '%s\n' "$out" > /dev/kmsg 2>/dev/null
	fi
	rm -rf "$work"
	return 0
}
