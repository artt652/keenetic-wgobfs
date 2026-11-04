#!/usr/bin/env bash
# Packs out/<variant>/ of one Entware architecture into
# out/wgobfs-kmod_<version>_<arch>.ipk.
#
#   scripts/build-ipk.sh <mipsel-3.4|mips-3.4|aarch64-3.10>
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${1:?usage: $0 <entware-arch>}
VERSION=$(sed -n 's/^\([0-9][^ ]*\).*/\1/p' "$ROOT/VERSION" | head -n 1)
PKG=wgobfs-kmod
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

D=$W/data/opt/lib/wgobfs
mkdir -p "$D/modules" "$W/data/opt/etc/init.d" "$W/ctrl"
variants=""
tool=""
for v in $(awk -v a="$ARCH" '$2 == a { print $1 }' "$ROOT/variants.conf"); do
	o=$ROOT/out/$v
	[ -f "$o/index" ] || { echo "missing build of $v ($o)" >&2; exit 1; }
	cat "$o/index" >>"$D/modules/index"
	while read -r _ file _; do
		install -m 0644 "$o/$file" "$D/modules/$file"
	done <"$o/index"
	tool=$o/wgobfs-tool
	variants="$variants $v"
done
[ -n "$tool" ] || { echo "no variants for $ARCH" >&2; exit 1; }

install -m 0755 "$tool" "$D/wgobfs-tool"
for l in genlid kmload texthash; do ln -s wgobfs-tool "$D/$l"; done
install -m 0755 "$ROOT/files/wgobfs-swap.sh" "$ROOT/files/wgobfs-mode.sh" "$D/"
install -m 0755 "$ROOT/files/S05wgobfs" "$W/data/opt/etc/init.d/S05wgobfs"

cat >"$W/ctrl/control" <<EOF
Package: $PKG
Version: $VERSION
Depends: ip-full
Section: kernel
Architecture: $ARCH
Installed-Size: $(du -sb "$W/data" | cut -f1)
Maintainer: artt652 <https://github.com/artt652/keenetic-wgobfs>
License: GPL-2.0
Description: WireGuard kernel module with a built-in wg-obfuscator client
 (STUN masking) for KeeneticOS 5.2 (Alpha 11 and newer). The module that
 fits the router is chosen by the .text hash of its stock wireguard.ko and
 swapped in at boot (Entware init S05wgobfs) with a guard against reboot
 loops. Tunnels are switched per tunnel with the AmneziaWG I5 parameter.
 Variants:$variants.
EOF
cat >"$W/ctrl/postinst" <<'EOF'
#!/bin/sh
/opt/etc/init.d/S05wgobfs enable
echo "wgobfs: the module is swapped at the next boot."
echo "        Now: sh /opt/lib/wgobfs/wgobfs-swap.sh swap"
echo "        Tunnel mode: sh /opt/lib/wgobfs/wgobfs-mode.sh set Wireguard0 auto <section>"
exit 0
EOF
cat >"$W/ctrl/prerm" <<'EOF'
#!/bin/sh
/opt/etc/init.d/S05wgobfs disable >/dev/null 2>&1
echo "wgobfs: autostart disabled; reboot to get the stock module back."
echo "        Tunnels in built-in mode keep the server endpoint: switch them first:"
echo "        sh /opt/lib/wgobfs/wgobfs-mode.sh set WireguardN external <section>"
exit 0
EOF
chmod 0755 "$W/ctrl/postinst" "$W/ctrl/prerm"
echo 2.0 >"$W/debian-binary"

O=(--owner=0 --group=0 --numeric-owner --sort=name --mtime=@"${SOURCE_DATE_EPOCH:-$(date +%s)}")
(cd "$W/ctrl" && tar "${O[@]}" -czf ../control.tar.gz ./)
(cd "$W/data" && tar "${O[@]}" -czf ../data.tar.gz ./)
mkdir -p "$ROOT/out"
IPK=$ROOT/out/${PKG}_${VERSION}_$ARCH.ipk
(cd "$W" && tar "${O[@]}" -czf "$IPK" ./debian-binary ./data.tar.gz ./control.tar.gz)
echo "Built $IPK ($(du -h "$IPK" | cut -f1)):$variants"
