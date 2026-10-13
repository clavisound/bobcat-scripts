#!/bin/bash
set -e

PRGNAM=gwmp-mux
VERSION=${VERSION:-1.1.0}
ARCH=$(dpkg --print-architecture)   # aarch64 -> arm64 on Bookworm
JOBS=${JOBS:-$(nproc)}

dpkg-buildpackage -us -uc -b -j"$JOBS"

ls -1 ../*.deb 2>/dev/null || ls -1 ./*.deb
