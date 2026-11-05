#!/bin/sh
# Per-tunnel choice between the external obfuscator (wg-obfuscator process on
# the router, peer endpoint 127.0.0.1:<source-lport>) and the built-in one
# (patched wireguard.ko, I5, peer endpoint = server obfuscator).
#
# Settings come from one place: the tunnel is linked to a section of
# /opt/etc/wg-obfuscator.conf, whose target/key/masking/max-dummy are used in
# both modes. Links and modes live in /opt/etc/wgobfs-tunnels.conf:
#   <WireguardN> <auto|internal|external> <section>
#
#   wgobfs-mode.sh list
#   wgobfs-mode.sh set <WireguardN> <auto|internal|external|off> [section]
#   wgobfs-mode.sh apply [WireguardN]
#
# auto = built-in when the patched module is loaded, external otherwise
# (stock module after a firmware update, autostart disabled, swap failed).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
TUN=/opt/etc/wgobfs-tunnels.conf
OBFCONF=/opt/etc/wg-obfuscator.conf
OBFINIT=/opt/etc/init.d/S99wg-obfuscator
SWAP=$HERE/wgobfs-swap.sh
CHANGED=0

say() { echo "wgobfs-mode: $*"; logger -t wgobfs "$*" 2>/dev/null; }
die() { echo "wgobfs-mode: ERROR: $*" >&2; exit 1; }

patched() { [ -e /sys/module/wireguard/parameters/genl_id ]; }

# sec_get SECTION KEY: value as wg-obfuscator reads it (# starts a comment).
sec_get() {
	[ -f "$OBFCONF" ] || return 0
	awk -v s="$1" -v k="$2" '
		{ sub(/#.*/, ""); gsub(/^[ \t\r]+|[ \t\r]+$/, "") }
		/^\[.*\]$/ { cur = substr($0, 2, length($0) - 2); gsub(/^[ \t]+|[ \t]+$/, "", cur); next }
		cur == s {
			i = index($0, "=")
			if (i) {
				kk = substr($0, 1, i - 1); vv = substr($0, i + 1)
				gsub(/[ \t]+$/, "", kk); gsub(/^[ \t]+/, "", vv)
				if (kk == k) v = vv
			}
		}
		END { print v }' "$OBFCONF"
}

sections() {
	[ -f "$OBFCONF" ] || return 0
	awk '{ sub(/#.*/, ""); gsub(/^[ \t\r]+|[ \t\r]+$/, "") }
		/^\[.*\]$/ { s = substr($0, 2, length($0) - 2); gsub(/^[ \t]+|[ \t]+$/, "", s); print s }' "$OBFCONF"
}

# Body of "interface X" in the running configuration.
RC=""
rc_load() { RC=$(ndmc -c 'show running-config' 2>/dev/null </dev/null); }
rc_block() { printf '%s\n' "$RC" | awk -v i="interface $1" '$0 == i { f = 1; next } f && /^!/ { exit } f { print }'; }

ndm_ok() {
	out=$(ndmc -c "$1" 2>&1 </dev/null); rc=$?
	echo "$out" | grep -qi error && rc=1
	[ $rc = 0 ] || say "router rejected: $1 -> $out"
	return $rc
}

eff_mode() {
	case "$1" in
	internal | external) echo "$1" ;;
	auto) patched && echo internal || echo external ;;
	*) echo none ;;
	esac
}

apply_internal() {
	iface=$1 sec=$2 blk=$3
	target=$(sec_get "$sec" target); key=$(sec_get "$sec" key)
	mask=$(sec_get "$sec" masking | tr a-z A-Z); dummy=$(sec_get "$sec" max-dummy)
	[ -n "$target" ] && [ -n "$key" ] || { say "$iface: section [$sec] has no target/key"; return 1; }
	case "$mask" in STUN) ;; *) mask=NONE ;; esac
	[ -n "$dummy" ] || dummy=4
	i5=$(sh "$SWAP" i5 "$key" "$mask" "$dummy") || { say "$iface: cannot build I5 from [$sec]"; return 1; }
	patched || say "$iface: built-in mode set, but the stock module is loaded"
	if ! printf '%s' "$blk" | grep -qiF "$i5"; then
		ok=0
		for a in '0 0 0 0 0 1 2 3 4 0 0 "" "" "" ""' '4 40 70 0 0 1 2 3 4 0 0 "" "" "" ""' \
			'3 10 50 15 20 100 200 300 400 0 0 "" "" "" ""'; do
			ndm_ok "interface $iface wireguard asc $a \"$i5\"" && { ok=1; break; }
		done
		[ $ok = 1 ] || { say "$iface: router did not accept ASC/I5"; return 1; }
		CHANGED=1 ASC_CHANGED=1
	fi
	set_endpoint "$iface" "$target" "$blk"
}

apply_external() {
	iface=$1 sec=$2 blk=$3
	lport=$(sec_get "$sec" source-lport)
	[ -n "$lport" ] || { say "$iface: section [$sec] has no source-lport"; return 1; }
	host=$(sec_get "$sec" source-if)
	case "$host" in '' | 0.0.0.0) host=127.0.0.1 ;; esac
	if printf '%s' "$blk" | grep -qi '<b 0x57474F42'; then
		ndm_ok "interface $iface wireguard asc 0 0 0 0 0 1 2 3 4 0 0 \"\" \"\" \"\" \"\" \"\"" ||
			ndm_ok "interface $iface no wireguard asc" ||
			{ patched && { say "$iface: cannot clear I5, external mode would obfuscate twice"; return 1; }; }
		CHANGED=1 ASC_CHANGED=1
	fi
	if [ -x "$OBFINIT" ] && ! pidof wg-obfuscator >/dev/null 2>&1; then
		"$OBFINIT" start >/dev/null 2>&1 </dev/null && say "started the external obfuscator"
	fi
	set_endpoint "$iface" "$host:$lport" "$blk"
}

set_endpoint() {
	iface=$1 ep=$2 blk=$3
	cur=$(printf '%s\n' "$blk" | awk '/^ +endpoint / { print $2; exit }')
	[ "$cur" = "$ep" ] && return 0
	peer=$(printf '%s\n' "$blk" | awk '/^ +wireguard peer / { print $3; exit }')
	[ -n "$peer" ] || { say "$iface: no peer"; return 1; }
	ndm_ok "interface $iface wireguard peer $peer endpoint $ep" || return 1
	CHANGED=1
	say "$iface: endpoint $cur -> $ep"
}

# A changed ASC makes NDM recreate the peer in the module without its
# endpoint and keepalive, and the tunnel stays silent (txbytes 0) until the
# interface is restarted. Restart it when it is configured up.
restart_if_up() {
	printf '%s\n' "$2" | grep -q '^ *up *$' || return 0
	ndmc -c "interface $1 down" >/dev/null 2>&1 </dev/null
	sleep 2
	ndmc -c "interface $1 up" >/dev/null 2>&1 </dev/null
	say "$1: restarted to apply the new ASC settings"
}

apply_one() {
	iface=$1 mode=$2 sec=$3 ASC_CHANGED=0
	blk=$(rc_block "$iface")
	[ -n "$blk" ] || { say "$iface: not in the router configuration"; return 1; }
	e=$(eff_mode "$mode")
	case "$e" in
	internal) apply_internal "$iface" "$sec" "$blk" ;;
	external) apply_external "$iface" "$sec" "$blk" ;;
	*) return 0 ;;
	esac || return 1
	[ "$ASC_CHANGED" = 0 ] || restart_if_up "$iface" "$blk"
	say "$iface: $mode -> $e"
}

apply() {
	only=${1:-}
	[ -f "$TUN" ] || return 0
	rc_load
	err=0
	while read -r iface mode sec _; do
		case "$iface" in '' | '#'*) continue ;; esac
		[ -z "$only" ] || [ "$only" = "$iface" ] || continue
		apply_one "$iface" "$mode" "$sec" || err=1
	done <"$TUN"
	[ $CHANGED = 0 ] || ndm_ok "system configuration save" >/dev/null
	return $err
}

case "${1:-}" in
list)
	[ -f "$TUN" ] || exit 0
	while read -r iface mode sec _; do
		case "$iface" in '' | '#'*) continue ;; esac
		echo "$iface $mode $sec $(eff_mode "$mode")"
	done <"$TUN" ;;
set)
	iface=${2:-} mode=${3:-} sec=${4:-}
	echo "$iface" | grep -qE '^Wireguard[0-9]{1,3}$' || die "interface: WireguardN"
	case "$mode" in auto | internal | external | off) ;; *) die "mode: auto|internal|external|off" ;; esac
	if [ "$mode" != off ]; then
		[ -n "$sec" ] || die "section is required"
		sections | grep -qxF "$sec" || die "no section [$sec] in $OBFCONF"
	fi
	touch "$TUN"
	grep -v "^$iface " "$TUN" >"$TUN.tmp" || true
	[ "$mode" = off ] || echo "$iface $mode $sec" >>"$TUN.tmp"
	mv "$TUN.tmp" "$TUN"
	[ "$mode" = off ] && { say "$iface: not managed any more (settings left as they are)"; exit 0; }
	apply "$iface" ;;
apply)
	apply "${2:-}" ;;
*)
	sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
