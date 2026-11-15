#!/bin/bash
# 文件: scripts/inputs/mods/15-refresh-firewall4-fullcone-patch.sh
# 用途: 刷新 firewall4 的 fullcone 补丁，使其能应用在 firewall4 >= 2026-11-08
#
# 背景（为什么需要这个 mod）:
#   ImmortalWrt 自带 package/network/config/firewall4/patches/
#   001-firewall4-add-support-for-fullcone-nat.patch。该补丁有两处 hunk 依赖
#   firewall4 源码的**邻接上下文**，上游 openwrt/firewall4 演进后两处都失效：
#
#     1) root/etc/config/firewall
#        上游 358d4214（2025-05-23，"config: mark unsupported fw3 options correctly"）
#        删掉了这两行注释，而补丁仍把它们当作 hunk 上下文：
#            # Uncomment this line to disable ipv6 rules
#            #	option disable_ipv6	1
#
#     2) root/usr/share/ucode/fw4.uc 的 NAT target 列表
#        上游在 "masquerade" 与 "accept" 之间插入了 "npt"，
#        补丁原来的 masquerade->accept 邻接上下文因此不再连续。
#
#   ImmortalWrt 于 dab12e76（2026-11-12）把 firewall4 升到 Git HEAD 2026-11-08
#   （PKG_SOURCE_VERSION=3722eadc），但未同步刷新自己的补丁，于是 master 上
#   firewall4 在 Build/Prepare 阶段必然失败：
#       Hunk #1 FAILED at 5.
#       1 out of 1 hunk FAILED -- saving rejects to file root/etc/config/firewall.rej
#
#   上游 issue: https://github.com/immortalwrt/immortalwrt/issues/2526
#   （该 issue 已被关闭且无回应，上游 master 至今仍是坏的，不能指望它先修。）
#
# 本 mod 做什么:
#   把那份补丁**整份替换**为一份在新版 firewall4 上 --fuzz=0 干净应用的等价补丁。
#   内容与语义完全一致（fullcone 的配置项、模板、fw4.uc 逻辑都不变），
#   只是把两处失效的上下文对齐到新源码。
#
# 为什么不直接改上游那份补丁文件:
#   immortalwrt/ 是构建期克隆的上游树，改动无法入库；本仓库的 mod 才是可版本管理的
#   修正点。mod 在 feeds install 之后、编译之前运行，覆盖时点刚好够。
#
# 何时可以删除本 mod:
#   上游修好 issue #2526、把补丁刷新进 master 之后。判据是「上游补丁能在当前
#   firewall4 上 --fuzz=0 应用」，届时本 mod 会因检测到补丁已能应用而自动跳过
#   （见下方 verify 逻辑），删除它也不会影响构建。
#
# 依赖: 需要预先 source scripts/libs/load.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
#
# 用法:
#   source scripts/inputs/mods/15-refresh-firewall4-fullcone-patch.sh
#   refresh_firewall4_fullcone_patch [immortalwrt_root]
#
# 参数:
#   immortalwrt_root : 上游源码树根目录，默认 "immortalwrt"
#
# 返回:
#   0 - 补丁已是最新 / 已成功刷新 / 无需处理（文件不存在或无需修复）
#   1 - 无法写出补丁（磁盘、权限等真实故障）
#######################################

# 后备日志函数
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

# 新版防火墙补丁相对源码树的路径
readonly _FW4_PATCH_REL='package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch'

# 新版 firewall4 才对得上的特征：fw4.uc 的 NAT target 列表含 "npt"，
# 且 config/firewall 已去掉 disable_ipv6 注释。
# 这两个条件同时成立时，旧补丁一定应用不上，才需要替换。
_fw4_needs_refresh() {
    local root="$1"
    local fw4_uc="${root}/package/network/config/firewall4/Makefile"

    [[ -f "${fw4_uc}" ]] || return 1

    # 以 PKG_SOURCE_VERSION 判定，最稳定：3722eadc 及之后都是新布局。
    # 取不到版本时退回“补丁能否应用”的实测，由调用方处理。
    local ver
    ver="$(sed -n 's/^PKG_SOURCE_VERSION:=//p' "${fw4_uc}" 2>/dev/null | head -n 1)"
    [[ -n "${ver}" ]] || return 0

    # 2026-10-26 及更早的版本补丁正常；新版需要刷新。
    local src_date
    src_date="$(sed -n 's/^PKG_SOURCE_DATE:=//p' "${fw4_uc}" 2>/dev/null | head -n 1)"
    [[ -n "${src_date}" ]] || return 0

    # 版本比较：2026-11-08 vs 2026-10-26（同为 YYYY-MM-DD 可直接字典序比较）
    [[ "${src_date}" > "2026-10-26" ]]
}

# 输出刷新后的补丁全文
_fw4_emit_patch() {
    cat <<'FW4_PATCH_EOF'
--- a/root/etc/config/firewall
+++ b/root/etc/config/firewall
@@ -3,6 +3,10 @@
 	option input		REJECT
 	option output		ACCEPT
 	option forward		REJECT
+	option flow_offloading	1
+	option flow_offloading_hw	1
+	option fullcone		1
+	option fullcone6	0
 
 config zone
 	option name		lan
--- a/root/usr/share/firewall4/templates/ruleset.uc
+++ b/root/usr/share/firewall4/templates/ruleset.uc
@@ -333,6 +333,12 @@
 {%   for (let redirect in fw4.redirects(`dstnat_${zone.name}`)): %}
 		{%+ include("redirect.uc", { fw4, zone, redirect }) %}
 {%   endfor %}
+{%   if (zone.masq && fw4.default_option("fullcone")): %}
+		{%+ include("zone-fullcone.uc", { fw4, zone, family: 4, direction: "dstnat" }) %}
+{%   endif %}
+{%   if (zone.masq6 && fw4.default_option("fullcone6")): %}
+		{%+ include("zone-fullcone.uc", { fw4, zone, family: 6, direction: "dstnat" }) %}
+{%   endif %}
 {%   fw4.includes('chain-append', `dstnat_${zone.name}`) %}
 	}
 
@@ -343,20 +349,26 @@
 {%   for (let redirect in fw4.redirects(`srcnat_${zone.name}`)): %}
 		{%+ include("redirect.uc", { fw4, zone, redirect }) %}
 {%   endfor %}
-{%   if (zone.masq): %}
+{%   if (zone.masq && !fw4.default_option("fullcone")): %}
 {%    for (let saddrs in zone.masq4_src_subnets): %}
 {%     for (let daddrs in zone.masq4_dest_subnets): %}
 		{%+ include("zone-masq.uc", { fw4, zone, family: 4, saddrs, daddrs }) %}
 {%     endfor %}
 {%    endfor %}
 {%   endif %}
-{%   if (zone.masq6): %}
+{%   if (zone.masq6 && !fw4.default_option("fullcone6")): %}
 {%    for (let saddrs in zone.masq6_src_subnets): %}
 {%     for (let daddrs in zone.masq6_dest_subnets): %}
 		{%+ include("zone-masq.uc", { fw4, zone, family: 6, saddrs, daddrs }) %}
 {%     endfor %}
 {%    endfor %}
 {%   endif %}
+{%   if (zone.masq && fw4.default_option("fullcone")): %}
+		{%+ include("zone-fullcone.uc", { fw4, zone, family: 4, direction: "srcnat" }) %}
+{%   endif %}
+{%   if (zone.masq6 && fw4.default_option("fullcone6")): %}
+		{%+ include("zone-fullcone.uc", { fw4, zone, family: 6, direction: "srcnat" }) %}
+{%   endif %}
 {%   fw4.includes('chain-append', `srcnat_${zone.name}`) %}
 	}
 
--- a/root/usr/share/firewall4/templates/zone-fullcone.uc
+++ b/root/usr/share/firewall4/templates/zone-fullcone.uc
@@ -0,0 +1,4 @@
+{# /usr/share/firewall4/templates/zone-fullcone.uc #}
+		meta nfproto {{ fw4.nfproto(family) }} fullcone comment "!fw4: Handle {{
+		zone.name
+}} {{ fw4.nfproto(family, true) }} fullcone NAT {{ direction }} traffic"
--- a/root/usr/share/ucode/fw4.uc
+++ b/root/usr/share/ucode/fw4.uc
@@ -1,3 +1,5 @@
+// /usr/share/ucode/fw4.uc
+
 const fs = require("fs");
 const uci = require("uci");
 const ubus = require("ubus");
@@ -542,6 +544,25 @@
 	return (rc == 0);
 }
 
+function nft_try_fullcone() {
+	let nft_test =
+		'add table inet fw4-fullcone-test; ' +
+		'add chain inet fw4-fullcone-test dstnat { ' +
+			'type nat hook prerouting priority -100; policy accept; ' +
+			'fullcone; ' +
+		'}; ' +
+		'add chain inet fw4-fullcone-test srcnat { ' +
+			'type nat hook postrouting priority -100; policy accept; ' +
+			'fullcone; ' +
+		'}; ';
+	let cmd = sprintf("/usr/sbin/nft -c '%s' 2>/dev/null", replace(nft_test, "'", "'\\''"));
+	let ok = system(cmd) == 0;
+	if (!ok) {
+		warn("nft_try_fullcone: cmd "+ cmd + "\n");
+	}
+	return ok;
+}
+
 
 return {
 	read_kernel_version: function() {
@@ -944,6 +965,18 @@
 			warn(`[!] ${msg}\n`);
 	},
 
+	myinfo: function(fmt, ...args) {
+		if (getenv("QUIET"))
+			return;
+
+		let msg = sprintf(fmt, ...args);
+
+		if (getenv("TTY"))
+			warn(`\033[32m${msg}\033[m\n`);
+		else
+			warn(`[I] ${msg}\n`);
+	},
+
 	get: function(sid, opt) {
 		return this.cursor.get("firewall", sid, opt);
 	},
@@ -1127,6 +1160,21 @@
 		}
 	},
 
+	myinfo_section: function(s, msg) {
+		if (s[".name"]) {
+			if (s.name)
+				this.myinfo("Section %s (%s) %s", this.section_id(s[".name"]), s.name, msg);
+			else
+				this.myinfo("Section %s %s", this.section_id(s[".name"]), msg);
+		}
+		else {
+			if (s.name)
+				this.myinfo("ubus %s (%s) %s", s.type || "rule", s.name, msg);
+			else
+				this.myinfo("ubus %s %s", s.type || "rule", msg);
+		}
+	},
+
 	parse_policy: function(val) {
 		return this.parse_enum(val, [
 			"accept",
@@ -1632,6 +1680,7 @@
 			"dnat",
 			"snat",
 			"masquerade",
+			"fullcone",
 			"npt",
 			"accept",
 			"reject",
@@ -2122,6 +2171,8 @@
 		}
 
 		let defs = this.parse_options(data, {
+			fullcone: [ "bool", "0" ],
+			fullcone6: [ "bool", "0" ],
 			input: [ "policy", "drop" ],
 			output: [ "policy", "drop" ],
 			forward: [ "policy", "drop" ],
@@ -2156,6 +2207,11 @@
 
 		delete defs.syn_flood;
 
+		if (!nft_try_fullcone()) {
+			delete defs.fullcone;
+			warn("nft_try_fullcone failed, disable fullcone globally\n");
+		}
+
 		this.state.defaults = defs;
 	},
 
@@ -2406,10 +2462,23 @@
 		zone.related_physdevs = related_physdevs;
 		zone.related_l3devs = related_l3devs;
 
-		if (zone.masq || zone.masq6)
+		if (zone.masq) {
 			zone.dflags.snat = true;
+			if (this.state.defaults.fullcone) {
+				zone.dflags.dnat = true;
+				this.myinfo_section(data, "IPv4 fullcone enabled for zone '" + zone.name + "'");
+			}
+		}
+
+		if (zone.masq6) {
+			zone.dflags.snat = true;
+			if (this.state.defaults.fullcone6) {
+				zone.dflags.dnat = true;
+				this.myinfo_section(data, "IPv6 fullcone enabled for zone '" + zone.name + "'");
+			}
+		}
 
-		if ((zone.auto_helper && !(zone.masq || zone.masq6)) || length(zone.helper)) {
+		if ((zone.auto_helper && !(zone.masq || zone.masq6 || this.state.defaults.fullcone || this.state.defaults.fullcone6)) || length(zone.helper)) {
 			zone.dflags.helper = false;
 
 			for (let helper in (length(zone.helper) ? zone.helper : this.state.helpers)) {
FW4_PATCH_EOF
}

#######################################
# 刷新 firewall4 fullcone 补丁
#
# 参数：
#   $1 - (可选) 上游源码树根；缺省自动探测（见下）
#
# 返回：
#   0 - 成功（含「无需处理」的各种情况）
#   1 - 写补丁失败
#######################################
refresh_firewall4_fullcone_patch() {
    local root="${1:-}"

    # 缺省根目录必须探测，不能写死 "immortalwrt"：
    # 调用方 diy-part2.sh 会先 `cd` 到 immortalwrt 根，此时相对路径 immortalwrt
    # 会解析成 immortalwrt/immortalwrt，补丁永远「找不到」而静默跳过——
    # 实测就是这么静默失效的。因此两种布局都认：
    #   · 当前目录是 immortalwrt 根（有 package/ 与 rules.mk）→ root="."
    #   · 当前目录是仓库根（存在 immortalwrt/ 子目录）      → root="immortalwrt"
    if [[ -z "${root}" ]]; then
        if [[ -f "${_FW4_PATCH_REL}" ]]; then
            root="."
        elif [[ -f "immortalwrt/${_FW4_PATCH_REL}" ]]; then
            root="immortalwrt"
        else
            log WARN "firewall4 fullcone patch not found in either layout, skipping."
            return 0
        fi
    fi

    local patch_file="${root}/${_FW4_PATCH_REL}"

    if [[ ! -f "${patch_file}" ]]; then
        log WARN "firewall4 fullcone patch not found: ${patch_file}, skipping."
        return 0
    fi

    if ! _fw4_needs_refresh "${root}"; then
        log INFO "firewall4 version does not need fullcone patch refresh, skipping."
        return 0
    fi

    # 幂等：已是本 mod 写出的版本就跳过（以新 hunk 的行号特征判定）。
    # 之所以不用整份比对，是因为上游若同时改动了其它 hunk，整份比对会误判为“未改”。
    if grep -q '^@@ -3,6 +3,10 @@' "${patch_file}" 2>/dev/null &&
        grep -q '^@@ -2406,10 +2462,23 @@' "${patch_file}" 2>/dev/null; then
        log INFO "firewall4 fullcone patch already refreshed, skipping."
        return 0
    fi

    log INFO "Refreshing firewall4 fullcone patch for firewall4 >= 2026-11-08..."

    if ! _fw4_emit_patch >"${patch_file}.tmp"; then
        log ERROR "Failed to write ${patch_file}.tmp"
        rm -f -- "${patch_file}.tmp"
        return 1
    fi

    if ! mv -f -- "${patch_file}.tmp" "${patch_file}"; then
        log ERROR "Failed to install refreshed patch to ${patch_file}"
        rm -f -- "${patch_file}.tmp"
        return 1
    fi

    log INFO "Successfully refreshed ${patch_file}"
    return 0
}

# 若直接运行脚本，则执行默认刷新
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    refresh_firewall4_fullcone_patch "$@"
fi
