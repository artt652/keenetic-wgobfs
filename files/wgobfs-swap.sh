#!/bin/sh
# Hot swap of the KeeneticOS WireGuard kernel module for the build with a
# built-in wg-obfuscator client.
#
# The module is chosen by the sha256 of the .text section of the stock
# /lib/modules/<kernel>/wireguard.ko: an entry in the index exists only for a
# stock module that is byte-identical to the one the patched build was made
# from (same module revision, same kernel options). No match = no swap.
#
# Nothing is written to flash: a reboot always brings back the stock module.
#
#   wgobfs-swap.sh select                  which module fits this router
#   wgobfs-swap.sh check                   checks only, changes nothing
#   wgobfs-swap.sh swap [module.ko]        loads the patched module
#   wgobfs-swap.sh restore                 back to the stock module (= reboot)
#   wgobfs-swap.sh status                  what is loaded now
#   wgobfs-swap.sh fix                     recreates missing WireGuard netdevs
#   wgobfs-swap.sh i5 <key> [STUN|NONE] [max-dummy]   prints the I5 value
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
KREL=$(uname -r)
STOCK=${WGOBFS_STOCK:-/lib/modules/$KREL/wireguard.ko}   # override for tests
INDEX=$DIR/modules/index
STATE=/tmp/wgobfs-swap   # tmpfs: forgotten on reboot, like the swap itself
TOOL=$DIR/wgobfs-tool
mkdir -p "$STATE" 2>/dev/null

say() { echo "wgobfs: $*"; }
die() { echo "wgobfs: ERROR: $*" >&2; exit 1; }

# ip that understands "type wireguard" and -d: Entware ip-full.
IP=ip
[ -x /opt/sbin/ip ] && IP=/opt/sbin/ip

patched_loaded() { [ -e /sys/module/wireguard/parameters/genl_id ]; }

# "<file> <variant> <revision>" of the module built for this stock module.
select_module() {
	[ -f "$STOCK" ] || { say "no stock module $STOCK"; return 1; }
	[ -f "$INDEX" ] || { say "no index $INDEX"; return 1; }
	h=$("$TOOL" texthash "$STOCK") || return 1
	echo "$h" >"$STATE/stock-text"
	awk -v h="$h" '$1 == h { print $2, $3, $4; found = 1; exit } END { exit !found }' "$INDEX"
}

# NDM interfaces WireguardN from the configuration.
ndm_wg_all() {
	ndmc -c 'show running-config' 2>/dev/null | awk '/^interface Wireguard[0-9]+/ { print $2 }'
}

# Kernel names of the WireGuard netdevs (nwgN); not the NDM names.
wg_netdevs() {
	$IP -d -o link show 2>/dev/null | awk -F': ' '/ wireguard( |$)/ { sub(/@.*/, "", $2); print $2 }'
}

# NDM interfaces WireguardN that are configured "up".
ndm_wg_up() {
	ndmc -c 'show running-config' 2>/dev/null | awk '
		/^interface Wireguard[0-9]+/ { cur = $2; up[cur] = 0; next }
		/^!/ { cur = "" ; next }
		cur != "" && /^ *up *$/ { up[cur] = 1 }
		END { for (i in up) if (up[i]) print i }'
}

# NDM looks the WireGuard netlink family id up once at boot and keeps using
# it, so every module we load must register with that id.
genl_id() {
	if [ -s "$STATE/genl_id" ]; then cat "$STATE/genl_id"; return 0; fi
	"$TOOL" genlid wireguard 2>/dev/null
}

# After the module is replaced NDM pushes keys and peers into the new
# netdevs again, but not the ASC parameters: the WGOB value in I5 never
# reaches the module and the tunnel stays plain WireGuard. Push the asc line
# of every interface that has a WGOB value again. Sending the same value
# twice is ignored by NDM, so it is cleared first and then restored.
resend_wgob() {
	ndmc -c 'show running-config' 2>/dev/null </dev/null | awk '
		/^interface Wireguard[0-9]+/ { cur = $2; next }
		/^!/ { cur = ""; next }
		cur != "" && /^ +wireguard asc / && /<[bB] 0x57474[fF]42/ { sub(/^ +/, ""); print cur " " $0 }' |
	while read -r i line; do
		ndmc -c "interface $i wireguard asc 0 0 0 0 0 1 2 3 4 0 0 \"\" \"\" \"\" \"\" \"\"" >/dev/null 2>&1 </dev/null
		if ndmc -c "interface $i $line" 2>&1 </dev/null | grep -qi error; then
			say "$i: could not push the asc/I5 settings again"
		else
			say "$i: asc/I5 pushed to the module"
		fi
	done
}

ndm_bounce() {
	for i in "$@"; do ndmc -c "interface $i down" >/dev/null 2>&1; done
	sleep 1
	for i in "$@"; do ndmc -c "interface $i up" >/dev/null 2>&1; done
}

check() {
	ko=${1:-}
	ok=1
	[ "$(id -u)" = 0 ] || { say "not root"; ok=0; }
	[ -x "$TOOL" ] || { say "$TOOL missing"; ok=0; }
	say "kernel $KREL"
	if sel=$(select_module); then
		set -- $sel
		say "stock module matches variant $2, revision $3"
		[ -n "$ko" ] || ko=$DIR/modules/$1
	else
		say "no module in this package fits the stock wireguard.ko (.text $(cut -c1-12 "$STATE/stock-text" 2>/dev/null))"
		ok=0
	fi
	if [ -d /sys/module/wireguard ]; then
		ref=$(cat /sys/module/wireguard/refcnt 2>/dev/null)
		if patched_loaded; then say "loaded: patched module"
		else say "loaded: stock module ($(cat /sys/module/wireguard/srcversion 2>/dev/null))"; fi
		[ "${ref:-1}" = 0 ] && say "refcount 0: ok" || { say "refcount ${ref:-?}, rmmod would fail"; ok=0; }
	else
		say "wireguard module is not loaded"
	fi
	if [ -n "$ko" ]; then
		if [ ! -f "$ko" ]; then say "$ko not found"; ok=0
		elif grep -q "vermagic=$KREL " "$ko" 2>/dev/null; then say "module vermagic: ok"
		else say "module vermagic does not match kernel $KREL"; ok=0; fi
	fi
	command -v rmmod >/dev/null || { say "rmmod missing"; ok=0; }
	if id=$(genl_id); then say "netlink family id: $id"
	else say "cannot get the netlink family id"; ok=0; fi
	say "WireGuard netdevs: $(wg_netdevs | tr '\n' ' ')"
	say "NDM WireGuard interfaces up: $(ndm_wg_up | tr '\n' ' ')"
	CHECKED_KO=$ko
	[ $ok = 1 ]
}

# Unloading the module removes every WireGuard netdev. Recreate them under
# the same names, then bounce the NDM interfaces so NDM pushes keys, peers
# and the asc/I5 settings into the new module.
reload() {
	ko=$1
	devs=$(wg_netdevs)
	[ -n "$devs" ] || die "no WireGuard netdevs found (is ip-full installed?); nothing changed"
	ups=$(ndm_wg_up)
	[ -s "$STATE/netdevs" ] || printf '%s\n' $devs >"$STATE/netdevs"
	devs=$(cat "$STATE/netdevs")
	say "taking down: $ups"
	for i in $ups; do ndmc -c "interface $i down" >/dev/null 2>&1; done
	sleep 1
	id=$(genl_id) || die "cannot get the netlink family id; nothing changed"
	echo "$id" >"$STATE/genl_id"
	rmmod wireguard || die "rmmod failed; nothing changed. Bring interfaces up: $ups"
	if ! "$TOOL" kmload "$ko" genl_id="$id"; then
		say "loading $ko failed, loading the stock module back; reboot to get the tunnels working"
		insmod "$STOCK" || die "stock insmod failed too, reboot the router"
	fi
	now=$("$TOOL" genlid wireguard 2>/dev/null)
	[ "$now" = "$id" ] && say "netlink family id kept: $id" || say "netlink family id changed: $id -> $now, reboot the router"
	for d in $devs; do
		[ -e "/sys/class/net/$d" ] || $IP link add "$d" type wireguard 2>/dev/null || say "could not recreate $d (opkg install ip-full)"
	done
	sleep 1
	for i in $ups; do ndmc -c "interface $i up" >/dev/null 2>&1; done
	sleep 3
	resend_wgob
	say "netdevs now: $(wg_netdevs | tr '\n' ' ')"
	missing=""
	for d in $devs; do [ -e "/sys/class/net/$d" ] || missing="$missing $d"; done
	[ -z "$missing" ] || say "missing after reload:$missing (a reboot restores the stock state)"
}

case "${1:-}" in
select)
	sel=$(select_module) || die "no module fits this firmware (stock .text $(cat "$STATE/stock-text" 2>/dev/null))"
	set -- $sel
	echo "$DIR/modules/$1 variant=$2 revision=$3" ;;
check)
	check "${2:-}" && say "all checks passed" || exit 1 ;;
swap)
	patched_loaded && { say "patched module already loaded"; exit 0; }
	check "${2:-}" || die "checks failed, nothing changed"
	reload "$CHECKED_KO"
	patched_loaded || die "the patched module is not loaded"
	say "patched module loaded. dmesg:"
	dmesg | grep -i -E "wireguard|wg-obfuscator" | tail -n 5 ;;
restore)
	# The stock module cannot keep the netlink family id: the clean way back
	# is a reboot.
	say "reboot the router to get the stock module back: ndmc -c 'system reboot'" ;;
status)
	check "" ;;
fix)
	[ -s "$STATE/netdevs" ] || die "no saved netdev list (fix only works after a swap since boot)"
	for d in $(cat "$STATE/netdevs"); do
		[ -e "/sys/class/net/$d" ] && continue
		$IP link add "$d" type wireguard && say "recreated $d" || say "could not recreate $d"
	done
	ups=$(ndm_wg_up); ndm_bounce $ups
	sleep 3
	resend_wgob
	say "netdevs now: $(wg_netdevs | tr '\n' ' ')" ;;
i5)
	shift
	[ $# -ge 1 ] || die "usage: $0 i5 <key> [STUN|NONE] [max-dummy 0..1024]"
	key=$1; m=$(printf '%s' "${2:-STUN}" | tr a-z A-Z); dm=${3:-4}
	len=$(printf '%s' "$key" | wc -c | tr -d ' ')
	[ "$len" -ge 1 ] && [ "$len" -le 255 ] || die "key must be 1..255 bytes"
	case "$key" in *'#'*|*'='*) die "key must not contain # or =" ;; esac
	case "$key" in '<'*'>') die "give the key itself, without the < > around it" ;; esac
	case "$m" in NONE) M=00 ;; STUN) M=01 ;; *) die "masking: STUN or NONE" ;; esac
	case "$dm" in ''|*[!0-9]*) die "max-dummy: 0..1024" ;; esac
	[ "$dm" -le 1024 ] || die "max-dummy: 0..1024"
	K=$(printf '%s' "$key" | hexdump -v -e '1/1 "%02X"' 2>/dev/null ||
	    printf '%s' "$key" | od -An -tx1 -v | tr -d ' \n' | tr a-f A-F)
	printf '<b 0x57474F4201%s%04X%s>\n' "$M" "$dm" "$K" ;;
*)
	sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
