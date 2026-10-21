#!/bin/bash
# Cross-compile ChirpStack (aarch64) on Slackware-15 x86_64 for Armbian Bookworm.
# Runs as a regular user. No sudo. No Slackware package is produced —
# just a runnable aarch64 binary + UI assets in $OUT_DIR.

set -euo pipefail

# Neutralize anything from the caller's environment that would override
# per-target settings in .cargo/config.toml.
unset CARGO_BUILD_TARGET
unset CARGO_TARGET_DIR

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$PATH"
export COREPACK_ENABLE_STRICT=0
export COREPACK_DEFAULT_TO_LATEST=0
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

###############################################################################
# Configuration — edit these if needed
###############################################################################
CHIRPSTACK_VERSION=${CHIRPSTACK_VERSION:-4.19.1}
CHIRPSTACK_TARBALL=${CHIRPSTACK_TARBALL:-$HOME/build/chirpstack-$CHIRPSTACK_VERSION}
CHIRPSTACK_URL="https://github.com/chirpstack/chirpstack/archive/refs/tags/v$CHIRPSTACK_VERSION.tar.gz"

BUILD_ROOT=${BUILD_ROOT:-$HOME/build}
CROSS_DIR=$BUILD_ROOT/cross
SRC_DIR=$BUILD_ROOT/src
OUT_DIR=$BUILD_ROOT/out

# Bootlin aarch64 toolchain. 2022.08-1 ships glibc 2.36 (matches Debian 12 /
# Bookworm). 2023.08-1 and later ship glibc 2.37+ which is too new.
BOOTLIN_VER=${BOOTLIN_VER:-2022.08-1}
BOOTLIN_NAME=aarch64--glibc--stable-$BOOTLIN_VER
BOOTLIN_TARBALL=$BOOTLIN_NAME.tar.bz2
BOOTLIN_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/$BOOTLIN_TARBALL"

CROSS_PREFIX=$CROSS_DIR/$BOOTLIN_NAME
TOOLCHAIN_SYSROOT=$CROSS_PREFIX/aarch64-buildroot-linux-gnu/sysroot
SYSROOT=$TOOLCHAIN_SYSROOT

# Two *different* triples:
#   - Rust's target name, used by rustup and `cargo --target`.
#   - GNU toolchain prefix, matches the filenames under $CROSS_PREFIX/bin.
TARGET_TRIPLE=aarch64-unknown-linux-gnu
GNU_TRIPLE=aarch64-buildroot-linux-gnu

###############################################################################
# Helpers
###############################################################################
log()  { printf '\033[1;32m>>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing tool: $1 (install it first)"
}

###############################################################################
# 0. Host preflight
###############################################################################
log "Checking host tools"
need curl
need tar
need pkg-config
need python3
need protoc
need node
need npm
need cargo
need rustc
need make
need rustup

if ! cargo --version >/dev/null 2>&1; then
  die "cargo is not working; install rustup first: https://rustup.rs"
fi

# Sanity: cargo/rustc must be the rustup-managed ones, not Slackware's stock.
case "$(command -v cargo)" in
  "$HOME/.cargo/bin/cargo") : ;;
  *) die "cargo on PATH is $(command -v cargo), not ~/.cargo/bin/cargo. \
Export PATH=\"\$HOME/.cargo/bin:\$PATH\" and retry." ;;
esac

# pnpm (via corepack, into $HOME)
pnpm --version

# pnpm: install a real pnpm via npm and never let corepack intercept.
rm -rf "$HOME/.local/lib64/node_modules/pnpm" "$HOME/.local/lib64/node_modules/.pnpm-"* \
       "$HOME/.local/lib/node_modules/pnpm" "$HOME/.local/lib/node_modules/.pnpm-"* \
       "$HOME/.local/bin/pnpm" "$HOME/.local/bin/pnpx" \
       "$HOME/.local/bin/pnpm.cmd" "$HOME/.local/bin/pnpx.cmd" \
       "$HOME/.cache/node/corepack"
log "Ensuring a real pnpm is installed"
npm config set prefix "$HOME/.local" >/dev/null
rm -rf "$HOME/.cache/node/corepack"
rm -f "$HOME/.local/bin/pnpm" "$HOME/.local/bin/pnpm.cmd" \
      "$HOME/.local/bin/pnpx" "$HOME/.local/bin/pnpx.cmd"
npm i -g --force pnpm@9 >/dev/null
PNPM_REAL=""
for d in "$HOME/.local/lib/node_modules/pnpm" "$HOME/.local/lib64/node_modules/pnpm"; do
  [ -f "$d/bin/pnpm.cjs" ] && { PNPM_REAL="$d/bin/pnpm.cjs"; break; }
done
[ -n "$PNPM_REAL" ] || die "pnpm install did not produce bin/pnpm.cjs under ~/.local/{lib,lib64}/node_modules/pnpm"
ln -sf "$PNPM_REAL" "$HOME/.local/bin/pnpm"
chmod +x "$HOME/.local/bin/pnpm"
hash -r 2>/dev/null || true
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$PATH"
case "$(command -v pnpm)" in
  "$HOME/.local/bin/pnpm") : ;;
  *) die "pnpm on PATH is $(command -v pnpm), not ~/.local/bin/pnpm" ;;
esac
pnpm --version

# Go protoc plugins
if ! command -v protoc-gen-go >/dev/null 2>&1 \
   || ! command -v protoc-gen-go-grpc >/dev/null 2>&1; then
  if command -v go >/dev/null 2>&1; then
    log "Installing Go protoc plugins into $HOME/go/bin"
    go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
  else
    die "missing protoc-gen-go / protoc-gen-go-grpc and no Go toolchain to build them"
  fi
fi

# grpc-web plugin
if ! command -v protoc-gen-grpc-web >/dev/null 2>&1; then
  log "Installing protoc-gen-grpc-web into $HOME/.local"
  npm config set prefix "$HOME/.local" >/dev/null
  npm i -g protoc-gen-grpc-web
fi

# Rust target
log "Ensuring Rust target $TARGET_TRIPLE is installed"
rustup target add "$TARGET_TRIPLE" >/dev/null

# rustc must actually see the std lib for the target, or the final build will
# fail with E0463.
if ! ls "$(rustc --print sysroot)"/lib/rustlib/ | grep -qx "$TARGET_TRIPLE"; then
  warn "rustc sysroot missing $TARGET_TRIPLE, re-adding"
  rustup component remove "rust-std-$TARGET_TRIPLE" 2>/dev/null || true
  rustup target add "$TARGET_TRIPLE"
fi

# rustup has a known failure mode where a target is "installed" but the
# rust-std rlibs were never unpacked (empty lib/ directory). Detect that and
# force a clean reinstall.
RUSTLIB="$(rustc --print sysroot)/lib/rustlib/$TARGET_TRIPLE/lib"
if ! ls "$RUSTLIB"/libcore-*.rlib >/dev/null 2>&1; then
  warn "rust-std rlibs for $TARGET_TRIPLE are missing ($RUSTLIB); reinstalling"
  rustup target remove "$TARGET_TRIPLE" 2>/dev/null || true
  rustup component remove "rust-std-$TARGET_TRIPLE" 2>/dev/null || true
  rustup target add "$TARGET_TRIPLE"
  ls "$RUSTLIB"/libcore-*.rlib >/dev/null 2>&1 \
    || die "rust-std for $TARGET_TRIPLE still missing after reinstall"
fi

# Bring ~/.local/bin and ~/go/bin back to the front after the rustup install.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$PATH"
export COREPACK_ENABLE_STRICT=0
export COREPACK_DEFAULT_TO_LATEST=0
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

###############################################################################
# 1. Cross toolchain
###############################################################################
mkdir -p "$CROSS_DIR"
if [ ! -d "$CROSS_PREFIX" ]; then
  log "Downloading Bootlin aarch64 toolchain ($BOOTLIN_VER)"
  (
    cd "$CROSS_DIR"
    curl -fL -o "$BOOTLIN_TARBALL" "$BOOTLIN_URL"
    tar xf "$BOOTLIN_TARBALL"
  )
else
  log "Cross toolchain already present at $CROSS_PREFIX"
fi

[ -x "$CROSS_PREFIX/bin/${GNU_TRIPLE}-gcc" ] \
  || die "cross gcc not found: $CROSS_PREFIX/bin/${GNU_TRIPLE}-gcc"
[ -d "$TOOLCHAIN_SYSROOT" ] \
  || die "toolchain sysroot not found: $TOOLCHAIN_SYSROOT"

###############################################################################

# Bootlin uses the classic (non-multiarch) layout.
for d in "$SYSROOT/usr/lib" "$SYSROOT/lib" "$SYSROOT/usr/lib64" "$SYSROOT/lib64"; do [ -d "$d" ] && { SYSROOT_LIB=$d; break; }; done; [ -n "$SYSROOT_LIB" ] || die "no libdir in $SYSROOT"
SYSROOT_PKGDIR=$SYSROOT_LIB/pkgconfig

###############################################################################
# 3. Cross-compile environment
###############################################################################
export CC=$CROSS_PREFIX/bin/${GNU_TRIPLE}-gcc
export CXX=$CROSS_PREFIX/bin/${GNU_TRIPLE}-g++
export AR=$CROSS_PREFIX/bin/${GNU_TRIPLE}-ar
export AS=$CROSS_PREFIX/bin/${GNU_TRIPLE}-as
export LD=$CROSS_PREFIX/bin/${GNU_TRIPLE}-ld
export RANLIB=$CROSS_PREFIX/bin/${GNU_TRIPLE}-ranlib
export STRIP=$CROSS_PREFIX/bin/${GNU_TRIPLE}-strip
export OBJCOPY=$CROSS_PREFIX/bin/${GNU_TRIPLE}-objcopy

export CFLAGS="--sysroot=$SYSROOT -O2 -fPIC"
export CXXFLAGS="--sysroot=$SYSROOT -O2 -fPIC"
export CPPFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include"
export LDFLAGS="--sysroot=$SYSROOT \
  -L$SYSROOT_LIB -L$SYSROOT/usr/lib -L$SYSROOT/lib \
  -Wl,-rpath-link,$SYSROOT_LIB -Wl,-rpath-link,$SYSROOT/lib"

export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_SYSROOT_DIR=$SYSROOT
export PKG_CONFIG_LIBDIR="$SYSROOT_PKGDIR:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

# Rust cross-linker plumbing.
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=$CC
export CC_aarch64_unknown_linux_gnu=$CC
export CXX_aarch64_unknown_linux_gnu=$CXX
export AR_aarch64_unknown_linux_gnu=$AR
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="\
-C link-arg=--sysroot=$SYSROOT \
-C link-arg=-L$SYSROOT_LIB \
-C link-arg=-L$SYSROOT/usr/lib \
-C link-arg=-L$SYSROOT/lib \
-C link-arg=-Wl,-rpath-link,$SYSROOT_LIB"

# *-sys crates.
export OPENSSL_DIR=$SYSROOT/usr
export OPENSSL_LIB_DIR=$SYSROOT_LIB
export OPENSSL_INCLUDE_DIR=$SYSROOT/usr/include
export SQLITE3_LIB_DIR=$SYSROOT_LIB
export SQLITE3_INCLUDE_DIR=$SYSROOT/usr/include
export PQ_LIB_DIR=$SYSROOT_LIB
export PQ_INCLUDE_DIR=$SYSROOT/usr/include
export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include"

# Shared cargo home (rustup's default).
export CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}

###############################################################################
# 4. Fetch ChirpStack source
###############################################################################
mkdir -p "$SRC_DIR"

# Anchor a relative tarball path at $BUILD_ROOT so it doesn't depend on cwd.
case "$CHIRPSTACK_TARBALL" in
  /*) : ;;
  *)  CHIRPSTACK_TARBALL="$BUILD_ROOT/${CHIRPSTACK_TARBALL##*/}" ;;
esac

SRC_TREE="$SRC_DIR/chirpstack-$CHIRPSTACK_VERSION"
rm -rf "$SRC_TREE"
tar xf "$CHIRPSTACK_TARBALL".tar.gz -C "$SRC_DIR"
# aply my dark mode patch
tar xf "$CHIRPSTACK_TARBALL-clv-dark-ui.tar.xz" -C "$SRC_TREE"

[ -d "$SRC_TREE" ] || die "extraction did not produce $SRC_TREE"
cd "$SRC_TREE"

# If the tree pins a toolchain via rust-toolchain.toml, provision the aarch64
# target for *that* toolchain, not just the default stable.
if [ -f rust-toolchain.toml ] || [ -f rust-toolchain ]; then
  PINNED=$(rustup show active-toolchain | awk '{print $1}')
  log "Toolchain pinned to $PINNED; ensuring target $TARGET_TRIPLE is installed for it"
  rustup target add --toolchain "$PINNED" "$TARGET_TRIPLE"
fi

###############################################################################
# 5. Cargo cross-compile config
###############################################################################
: "${TARGET_TRIPLE:?TARGET_TRIPLE is unset or empty}"
: "${CC:?CC is unset}"
: "${AR:?AR is unset}"

mkdir -p "$SRC_TREE/.cargo"
cat > "$SRC_TREE/.cargo/config.toml" <<EOF
[target.$TARGET_TRIPLE]
linker = "$CC"
ar = "$AR"
EOF

log "Wrote $SRC_TREE/.cargo/config.toml:"
cat "$SRC_TREE/.cargo/config.toml"

###############################################################################
# 6. (Optional) allowlist injection from Debian rules
###############################################################################
# Paste the python3 snippet from your debian/rules here, if any, e.g.:
#
# python3 - <<'PYEOF'
# import pathlib
# p = pathlib.Path("chirpstack/Cargo.toml")
# txt = p.read_text()
# # ... inject allowlist ...
# p.write_text(txt)
# PYEOF
log "Skipping allowlist injection (edit the script if your debian/rules needs it)"

###############################################################################
# 7. gRPC / protobuf codegen (host tools, arch-independent output)
###############################################################################
log "Generating Rust + grpc-web protobuf bindings"

# pnpm (any 8.x or 9.x we've tried) rejects a pnpm-workspace.yaml without a
# `packages:` key. ChirpStack ships several such files; patch them all before
# any pnpm invocation.
while IFS= read -r ws; do
  if ! grep -q '^packages:' "$ws"; then
    log "Patching $ws (adding packages: entry)"
    { printf 'packages:\n  - "."\n'; cat "$ws"; } > "$ws.new"
    mv "$ws.new" "$ws"
  fi
done < <(find . -maxdepth 4 -name pnpm-workspace.yaml)

rm -rf api/grpc-web/node_modules api/grpc-web/pnpm-lock.yaml

mkdir -p api/grpc-web/node_modules/grpc-tools/bin
ln -sf "$(command -v protoc)" api/grpc-web/node_modules/grpc-tools/bin/protoc

( cd api && make rust )
( cd api && make grpc-web )

###############################################################################
# 8. Web UI (host tools, static output)
###############################################################################
log "Building web UI"
( cd ui && pnpm install --frozen-lockfile && pnpm build )

###############################################################################
# 9. Cross-compile the Rust server
###############################################################################
log "Cross-compiling chirpstack for $TARGET_TRIPLE (this takes a while)"
( cd chirpstack && cargo build --release --target "$TARGET_TRIPLE" -j 1 )

BIN=target/$TARGET_TRIPLE/release/chirpstack
[ -f "$BIN" ] || die "expected binary not produced at $BIN"

###############################################################################
# 10. Stage results for shipping
###############################################################################
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/bin" "$OUT_DIR/ui" "$OUT_DIR/etc"

install -m 0755 "$BIN" "$OUT_DIR/bin/chirpstack"
"$STRIP" "$OUT_DIR/bin/chirpstack" || true

if [ -d ui/build ]; then
  cp -a ui/build/. "$OUT_DIR/ui/"
  find "$OUT_DIR/ui" -name '*.map' -delete || true
fi

if [ -f chirpstack/configuration/chirpstack.toml ]; then
  install -m 0644 chirpstack/configuration/chirpstack.toml \
    "$OUT_DIR/etc/chirpstack.toml"
fi

###############################################################################
# 11. Report
###############################################################################
log "Verifying the produced binary"
file "$OUT_DIR/bin/chirpstack" || true
if command -v readelf >/dev/null 2>&1; then
  echo "--- NEEDED libs (must exist on Armbian Bookworm) ---"
  readelf -d "$OUT_DIR/bin/chirpstack" | grep NEEDED || true
  echo "--- Required GLIBC symbol versions ---"
  readelf -sW "$OUT_DIR/bin/chirpstack" 2>/dev/null \
    | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n5 || true
fi

cat <<EOF

============================================================
Done.

Binary:      $OUT_DIR/bin/chirpstack
UI assets:   $OUT_DIR/ui/
Config tmpl: $OUT_DIR/etc/chirpstack.toml

Ship to Armbian Bookworm:

  scp $OUT_DIR/bin/chirpstack        user@armbian:/tmp/
  scp -r $OUT_DIR/ui                 user@armbian:/tmp/chirpstack-ui

On the Armbian host (as root):

  install -m 0755 /tmp/chirpstack /usr/local/bin/chirpstack
  mkdir -p /usr/share/chirpstack/ui
  cp -a /tmp/chirpstack-ui/. /usr/share/chirpstack/ui/
  # ensure runtime deps are present (Bookworm ships these by default):
  apt-get install -y libssl3 libsqlite3-0 libpq5

  # quick sanity check:
  ldd /usr/local/bin/chirpstack
  /usr/local/bin/chirpstack --help

============================================================
EOF
