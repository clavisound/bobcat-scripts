#!/bin/bash
set -e
PKG=helium-gateway
VER=1.3.0
ARCH=arm64
ROOT=build/${PKG}_${VER}_${ARCH}

# 1. Create the filesystem layout
mkdir -p ${ROOT}/DEBIAN
mkdir -p ${ROOT}/usr/bin
mkdir -p ${ROOT}/etc/helium_gateway
mkdir -p ${ROOT}/lib/systemd/system

# 2. Install files
install -m 0755 target/release/helium_gateway ${ROOT}/usr/bin/helium_gateway
install -m 0644 config/settings.toml                  ${ROOT}/etc/helium_gateway/settings.toml

# 3. Control file
cat > ${ROOT}/DEBIAN/control <<EOF
Package: ${PKG}
Version: ${VER}
Section: net
Priority: optional
Architecture: ${ARCH}
Maintainer: Your Name <you@example.com>
Description: Helium Gateway
 The Helium Gateway application for Linux-based LoRaWAN gateways.
EOF

# 4. systemd unit (optional)
cat > ${ROOT}/lib/systemd/system/helium-gateway.service <<'EOF'
[Unit]
Description=Helium Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/helium_gateway -c /etc/helium_gateway/settings.toml server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 5. Build the .deb
dpkg-deb --build --root-owner-group ${ROOT}
