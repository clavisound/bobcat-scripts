# --- workspace (all under $HOME) ---
mkdir -p ~/build/{src,pkg,out,cross,sysroot}
cd ~/build

# --- Rust (installs into ~/.cargo, ~/.rustup) ---
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
rustup target add aarch64-unknown-linux-gnu

# --- Go plugins (install into ~/go/bin) ---
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# --- grpc-web plugin (into ~/.local via npm prefix, no sudo) ---
npm config set prefix ~/.local
npm i -g protoc-gen-grpc-web

# --- pnpm (via corepack, no sudo) ---
corepack enable --install-directory ~/.local/bin
corepack prepare pnpm@latest --activate

# --- cross toolchain, unpacked under $HOME (Bootlin example) ---
cd ~/build/cross
wget https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/\
aarch64--glibc--stable-2024.05-1.tar.xz
tar xf aarch64--glibc--stable-2024.05-1.tar.xz
# -> ~/build/cross/aarch64--glibc--stable-2024.05-1/

# --- aarch64 sysroot: place your target libs here ---
#     (extract Slackware-aarch64 'l'/'d' packages into ~/build/sysroot,
#      or use the toolchain's bundled sysroot -- see below)
