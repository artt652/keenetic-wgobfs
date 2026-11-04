#!/usr/bin/env bash
# Builds the stock and the patched wireguard.ko of one variant for every
# revision in revisions.conf, plus wgobfs-tool, into out/<variant>/.
#
#   scripts/build-variant.sh <variant>
#
# Environment (all optional):
#   WORK     work directory (default: work/), holds the SDK, toolchains, sources
#   SDK_TAG  keenetic-sdk tag (default 5.01.C.8.0-2)
#   JOBS     make -j (default nproc)
#
# Must run as a regular user (the SDK refuses root). Needs the packages from
# the keenetic-sdk README, plus xxd and zstd.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${1:?usage: $0 <variant>}
WORK=${WORK:-$ROOT/work}
SDK_TAG=${SDK_TAG:-5.01.C.8.0-2}
JOBS=${JOBS:-$(nproc)}
OUT=$ROOT/out/$VARIANT

read -r _ ARCH PLATFORM MODELS < <(awk -v v="$VARIANT" '$1 == v' "$ROOT/variants.conf")
[ -n "${ARCH:-}" ] || { echo "unknown variant $VARIANT" >&2; exit 2; }
MODEL=${MODELS%% *}
case $ARCH in
mipsel-*) KARCH=mips;  TRIPLE=mipsel-ndms-linux-musl ;;
mips-*)   KARCH=mips;  TRIPLE=mips-ndms-linux-musl ;;
aarch64-*) KARCH=arm64; TRIPLE=aarch64-ndms-linux-musl ;;
esac
msg() { echo -e "\e[1;33m== $*\e[0m"; }
mkdir -p "$WORK" "$OUT"

# 1. SDK and the model's kernel tree (configured and prepared for modules).
SDK=$WORK/sdk
if [ ! -d "$SDK/.git" ]; then
	msg "Cloning keenetic-sdk $SDK_TAG"
	git -c advice.detachedHead=false clone -q --depth 1 --branch "$SDK_TAG" https://github.com/keenetic/keenetic-sdk.git "$SDK"
fi
msg "Preparing the kernel of $MODEL ($PLATFORM)"
( cd "$SDK" && ./configure.sh "$MODEL" >/dev/null && make -j"$JOBS" target/linux/prepare >"$OUT/prepare.log" 2>&1 ) ||
	{ tail -n 40 "$OUT/prepare.log"; exit 1; }
LINUX=$(ls -d "$SDK"/build_dir/target-*/linux-"${PLATFORM}_$MODEL"/linux-4.9)

# 2. Toolchain: the archive the SDK names for this architecture, checked
#    against the sha256 in the SDK.
TC=$WORK/toolchain-$TRIPLE
if [ ! -x "$TC/bin/$TRIPLE-gcc" ]; then
	read -r TFILE THASH < <(awk -v t="x86_64-pc-linux-gnu_$TRIPLE.tar.xz" '
		/PKG_SOURCE:=/ && index($0, t) { sub(/.*PKG_SOURCE:=/, ""); f = $0; next }
		f && /PKG_HASH:=/ { sub(/.*PKG_HASH:=/, ""); print f, $0; exit }' "$SDK/toolchain/dl/Makefile")
	TURL=$(awk -F':=' '/^PKG_VERSION_REAL:=/ { print $2; exit }' "$SDK/toolchain/dl/Makefile")
	msg "Downloading toolchain $TFILE"
	curl -sSLf -o "$WORK/$TFILE" "https://github.com/keenetic/crosstool-ng/releases/download/$TURL/$TFILE"
	echo "$THASH  $WORK/$TFILE" | sha256sum -c --quiet
	mkdir -p "$TC"
	tar -xJf "$WORK/$TFILE" -C "$TC" --strip-components=1
	rm -f "$WORK/$TFILE"
fi
export PATH=$TC/bin:$PATH
KMAKE=(make -C "$LINUX" ARCH="$KARCH" CROSS_COMPILE="$TRIPLE-" KBUILD_HAVE_NLS=no CONFIG_SHELL=/bin/bash -j"$JOBS")
"${KMAKE[@]}" modules_prepare >"$OUT/modules_prepare.log" 2>&1 || { tail -n 40 "$OUT/modules_prepare.log"; exit 1; }

# 3. Module sources.
WG=$WORK/wireguard
if [ ! -d "$WG/.git" ]; then
	git clone -q --filter=blob:none https://github.com/keenetic/wireguard.git "$WG"
fi

texthash() { "$TRIPLE-objcopy" -O binary -j .text "$1" "$1.text" && sha256sum <"$1.text" | cut -d' ' -f1 && rm -f "$1.text"; }
modinfo_field() { "$TRIPLE-readelf" -p .modinfo "$1" | sed -n "s/.*\] *$2=//p" | head -n 1; }

: >"$OUT/index"
while read -r REV; do
	case $REV in '' | '#'*) continue ;; esac
	R=${REV##*-}
	for kind in stock patched; do
		S=$WORK/src-$VARIANT-$R-$kind
		rm -rf "$S"; mkdir -p "$S"
		git -C "$WG" archive "$REV" src | tar -x -C "$S"
		if [ $kind = patched ]; then
			patch -s -p1 -d "$S" <"$ROOT/patches/wgobfs.patch"
		fi
		msg "Building $kind $REV for $VARIANT"
		"${KMAKE[@]}" M="$S/src" KBUILD_MODPOST_WARN=1 modules >"$OUT/build-$R-$kind.log" 2>&1 ||
			{ tail -n 40 "$OUT/build-$R-$kind.log"; exit 1; }
		"$TRIPLE-strip" --strip-debug "$S/src/wireguard.ko"
		cp "$S/src/wireguard.ko" "$OUT/$VARIANT-$R-$kind.ko"
		rm -rf "$S"
	done
	STOCK_HASH=$(texthash "$OUT/$VARIANT-$R-stock.ko")
	SRCV=$(modinfo_field "$OUT/$VARIANT-$R-stock.ko" srcversion)
	echo "$STOCK_HASH $VARIANT-$R.ko $VARIANT $R $SRCV" >>"$OUT/index"
	mv "$OUT/$VARIANT-$R-patched.ko" "$OUT/$VARIANT-$R.ko"
	echo "  $REV: stock .text ${STOCK_HASH:0:12}, srcversion $SRCV, vermagic $(modinfo_field "$OUT/$VARIANT-$R.ko" vermagic)"
done <"$ROOT/revisions.conf"

# 4. The router-side helper for this architecture.
"$TRIPLE-gcc" -static -Os -s -Wall -o "$OUT/wgobfs-tool" "$ROOT/tools/wgobfs-tool.c"
echo "$ARCH" >"$OUT/arch"
msg "Done: $OUT"
cat "$OUT/index"
