# ChirpStack 4.19.1 Debian packaging

Build steps:

1. Download upstream source:
   https://github.com/chirpstack/chirpstack/archive/refs/tags/v4.19.1.tar.gz
   (or the GitHub release tarball)

2. Extract:
   tar xf chirpstack-4.19.1.tar.gz
   cd chirpstack-4.19.1

3. Extract this debian/ tarball into the tree:
   tar xf ../chirpstack-debian-4.19.1.tar.gz

4. Install build dependencies:
   sudo apt install debhelper cargo rustc pkg-config libclang-dev llvm-dev \
     protobuf-compiler libprotobuf-dev libssl-dev libsqlite3-dev libpq-dev \
     nodejs npm
   # plus, if not packaged:
   #   pnpm (via corepack or npm i -g)
   #   protoc-gen-grpc-web (from grpc-web GitHub releases)
   #   protoc-gen-go, protoc-gen-go-grpc (via apt or go install)

5. Build:
   dpkg-buildpackage -us -uc -b

6. Install the resulting .deb:
   sudo dpkg -i ../chirpstack_4.19.1_arm64.deb

## Packaging info

If building natively on bobcat it has 2G of memory sto LTO is disabled and jobs are 1 because of rust diesel. It needs too much memory. Same goes with chripstack bin I think.

Compiling requires around 3Gbytes of RAM. Cross compiled with LTO enabled is using 1.6% of ME vs 2%.
