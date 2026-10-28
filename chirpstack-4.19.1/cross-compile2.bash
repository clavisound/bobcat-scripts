#!/bin/bash
# Cross-compile ChirpStack (aarch64) on Slackware-15 x86_64 for Armbian Bookworm.
# Runs as a regular user. No sudo. No Slackware package is produced 
# just a runnable aarch64 binary + UI assets in $OUT_DIR.
#
# Options:
#   --ui-only    Only rebuild the web UI; skip protobuf codegen and the Rust
#                cross-compile. Reuses an existing $SRC_TREE and $OUT_DIR.
#   --no-clean   Do not delete $SRC_TREE or $OUT_DIR before building. Reuse
#                the existing source tree and previously staged binaries/assets.
#   -h, --help   Show help.

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
# Configuration  edit these if needed
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
# CLI options
###############################################################################
UI_ONLY=0
NO_CLEAN=0

usage() {
  cat <<EOF
Usage: $0 [--ui-only] [--no-clean] [-h|--help]

  --ui-only    Only rebuild the web UI; skip protobuf codegen and the Rust
               cross-compile. Requires a previous full build (or --no-clean)
               so that \$OUT_DIR/bin/chirpstack already exists.
  --no-clean   Do not delete \$SRC_TREE or \$OUT_DIR before building. Reuse
               the existing source tree and previously staged binaries/assets.
  -h, --help   Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ui-only)  UI_ONLY=1 ;;
    --no-clean) NO_CLEAN=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

if [ "$UI_ONLY" = 1 ] && [ "$NO_CLEAN" = 0 ]; then
  warn "--ui-only without --no-clean will wipe \$SRC_TREE and \$OUT_DIR;"
  warn "the previously built binary in \$OUT_DIR/bin will be lost."
  warn "Proceeding anyway in 3s (Ctrl-C to abort)..."
  sleep 3
fi

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

if [ "$NO_CLEAN" = 1 ] && [ -d "$SRC_TREE" ]; then
  log "Reusing existing source tree at $SRC_TREE (--no-clean)"
else
  rm -rf "$SRC_TREE"
  tar xf "$CHIRPSTACK_TARBALL".tar.gz -C "$SRC_DIR"
  # apply my dark mode patch
  tar xf "$CHIRPSTACK_TARBALL-clv-dark-ui.tar.xz" -C "$SRC_TREE"
fi

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
if [ "$UI_ONLY" = 1 ]; then
  log "Skipping allowlist injection (--ui-only)"
else
  log "Skipping allowlist injection (edit the script if your debian/rules needs it)"
fi

###############################################################################
# 6b. Patch pnpm-workspace.yaml (always needed, cheap and idempotent)
###############################################################################
# pnpm (any 8.x or 9.x we've tried) rejects a pnpm-workspace.yaml without a
# `packages:` key. ChirpStack ships several such files; patch them all before
# *any* pnpm invocation (step 7 and step 8).
while IFS= read -r ws; do
  if ! grep -q '^packages:' "$ws"; then
    log "Patching $ws (adding packages: entry)"
    { printf 'packages:\n  - "."\n'; cat "$ws"; } > "$ws.new"
    mv "$ws.new" "$ws"
  fi
done < <(find . -maxdepth 4 -name pnpm-workspace.yaml)

###############################################################################
# 7. gRPC / protobuf codegen (host tools, arch-independent output)
###############################################################################
log "Generating grpc-web protobuf bindings"

# pnpm (any 8.x or 9.x we've tried) rejects a pnpm-workspace.yaml without a
# `packages:` key. ChirpStack ships several such files; patch them all before
# any pnpm invocation. (This is also done in step 6b, but keep it here so the
# step is self-contained.)
while IFS= read -r ws; do
  if ! grep -q '^packages:' "$ws"; then
    log "Patching $ws (adding packages: entry)"
    { printf 'packages:\n  - "."\n'; cat "$ws"; } > "$ws.new"
    mv "$ws.new" "$ws"
  fi
done < <(find . -maxdepth 4 -name pnpm-workspace.yaml)

# Regenerate grpc-web TypeScript/JS modules. These are imported by ui/ and
# must always be up to date, even in --ui-only mode.
if [ "$NO_CLEAN" = 1 ] && [ -d api/grpc-web/node_modules ]; then
  log "Reusing existing api/grpc-web/node_modules (--no-clean)"
else
  rm -rf api/grpc-web/node_modules api/grpc-web/pnpm-lock.yaml
fi

mkdir -p api/grpc-web/node_modules/grpc-tools/bin
ln -sf "$(command -v protoc)" api/grpc-web/node_modules/grpc-tools/bin/protoc

( cd api && make grpc-web )

# Rust server codegen is only needed for the Rust build.
if [ "$UI_ONLY" = 1 ]; then
  log "Skipping Rust protobuf codegen (--ui-only)"
else
  log "Generating Rust protobuf bindings"
  ( cd api && make rust )
fi

###############################################################################
# 8. Web UI (host tools, static output)
###############################################################################
log "Building web UI"
if [ "$NO_CLEAN" = 1 ] && [ -d ui/node_modules ]; then
  log "Reusing existing ui/node_modules (--no-clean)"
  ( cd ui && pnpm build )
else
  ( cd ui && pnpm install --frozen-lockfile && pnpm build )
fi

log "Building web UI"
( cd ui && pnpm install --frozen-lockfile && pnpm build )

if [ ! -f ui/build/index.html ]; then
  die "step 8 did not produce ui/build/index.html — UI build failed"
fi
log "UI build OK: $(find ui/build -type f | wc -l) files, $(du -sh ui/build | cut -f1)"

# to re-run build
touch chirpstack/src/api/mod.rs
log "Cross-compiling chirpstack for $TARGET_TRIPLE (this takes a while)"
( cd chirpstack && cargo build --release --target "$TARGET_TRIPLE" -j 1 )


###############################################################################
# 9. Cross-compile the Rust server
###############################################################################
BIN=""
if [ "$UI_ONLY" = 1 ]; then
  log "Skipping Rust cross-compile (--ui-only)"

  # Locate any previously built binary so step 10 doesn't die with BIN unset.
  for cand in \
    "chirpstack/target/$TARGET_TRIPLE/release/chirpstack" \
    "target/$TARGET_TRIPLE/release/chirpstack"; do
    [ -f "$cand" ] && { BIN="$cand"; break; }
  done
else
  # The Rust server embeds ui/build/ at compile time. If ui/build/ was
  # regenerated (step 8), we must make sure the embedding crate recompiles.
  if [ "$NO_CLEAN" = 1 ]; then
    log "Forcing chirpstack crate recompile so the new UI is embedded (--no-clean)"
    ( cd chirpstack && cargo clean -p chirpstack 2>/dev/null || true )
  fi

  log "Cross-compiling chirpstack for $TARGET_TRIPLE (this takes a while)"
  ( cd chirpstack && cargo build --release --target "$TARGET_TRIPLE" -j 1 )

  # cargo places target/ either at $SRC_TREE (workspace root) or at
  # $SRC_TREE/chirpstack (if the crate is its own root). Try both.
  for cand in \
    "chirpstack/target/$TARGET_TRIPLE/release/chirpstack" \
    "target/$TARGET_TRIPLE/release/chirpstack"; do
    [ -f "$cand" ] && { BIN="$cand"; break; }
  done
  [ -n "$BIN" ] || die "cargo build finished but no binary found under chirpstack/target/ or target/"
  log "Built binary: $PWD/$BIN"

  # The thing the Rust build actually embeds:
  [ -f ui/build/index.html ] || die "ui/build/index.html missing; Rust would embed an empty UI"
fi

###############################################################################
# 10. Stage results for shipping
###############################################################################
if [ "$NO_CLEAN" = 1 ]; then
  log "Keeping existing $OUT_DIR contents (--no-clean)"
else
  rm -rf "$OUT_DIR"
fi
mkdir -p "$OUT_DIR/bin" "$OUT_DIR/ui" "$OUT_DIR/etc"

if [ -n "$BIN" ]; then
  install -m 0755 "$BIN" "$OUT_DIR/bin/chirpstack"
  "$STRIP" "$OUT_DIR/bin/chirpstack" || true
else
  warn "No binary to stage (UI-only run with no previous build?)"
fi

# sanity: staged binary must not be older than the built one
if [ -n "$BIN" ] && [ -f "$OUT_DIR/bin/chirpstack" ]; then
  s=$(stat -c %Y "$OUT_DIR/bin/chirpstack" 2>/dev/null || echo 0)
  b=$(stat -c %Y "$BIN")
  [ "$s" -ge "$b" ] || die "staged binary older than $BIN — install did not run?"
fi

###############################################################################
# 11. Report
###############################################################################
log "Verifying the produced binary"
if [ -f "$OUT_DIR/bin/chirpstack" ]; then
  file "$OUT_DIR/bin/chirpstack" || true
  if command -v readelf >/dev/null 2>&1; then
    echo "--- NEEDED libs (must exist on Armbian Bookworm) ---"
    readelf -d "$OUT_DIR/bin/chirpstack" | grep NEEDED || true
    echo "--- Required GLIBC symbol versions ---"
    readelf -sW "$OUT_DIR/bin/chirpstack" 2>/dev/null \
      | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n5 || true
  fi
else
  warn "No binary at $OUT_DIR/bin/chirpstack (UI-only build, none staged)"
fi

if [ "$UI_ONLY" = 1 ]; then
  cat <<EOF

============================================================
Done (UI only).

UI assets:   $OUT_DIR/ui/
Binary:      $OUT_DIR/bin/chirpstack  (unchanged / may be absent)

Ship just the UI:

  scp -r $OUT_DIR/ui user@armbian:/tmp/chirpstack-ui
  # on the Armbian host:
  cp -a /tmp/chirpstack-ui/. /usr/share/chirpstack/ui/

============================================================
EOF
else
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
fi
