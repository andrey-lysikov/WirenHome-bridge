#!/bin/bash
#  Copyright © AndreyLysikov
#  SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Usage: build-deb.sh <version> <binary> <output dir>
VERSION="$1"
BINARY="$2"
OUT="$3"

HERE="$(cd "$(dirname "$0")" && pwd)"
ARCH="$(dpkg --print-architecture)"
ROOT="$(mktemp -d)/wirenhome-bridge"

install -D -m 0755 "$BINARY" "$ROOT/usr/bin/wirenhome-bridge"
install -D -m 0644 "$HERE/wirenhome-bridge.service" "$ROOT/lib/systemd/system/wirenhome-bridge.service"
install -D -m 0644 "$HERE/../LICENSE" "$ROOT/usr/share/doc/wirenhome-bridge/copyright"
for script in postinst prerm postrm; do
    install -D -m 0755 "$HERE/$script" "$ROOT/DEBIAN/$script"
done
# /etc/wirenhome-bridge.conf and the confed schema are written by the bridge itself (settings page in the web UI).

# Updates come from the project's signed apt repository once its public key is in the tree.
if [ -f "$HERE/wirenhome-bridge.gpg" ]; then
    install -D -m 0644 "$HERE/wirenhome-bridge.gpg" "$ROOT/usr/share/keyrings/wirenhome-bridge.gpg"
    install -D -m 0644 "$HERE/wirenhome-bridge.list" "$ROOT/etc/apt/sources.list.d/wirenhome-bridge.list"
    echo "/etc/apt/sources.list.d/wirenhome-bridge.list" >> "$ROOT/DEBIAN/conffiles"
else
    echo "warning: packaging/wirenhome-bridge.gpg is missing, the package will not receive apt updates" >&2
fi

# dpkg-shlibdeps needs a debian/control to run, so give it a throwaway one.
SHLIBS="$(mktemp -d)"
mkdir -p "$SHLIBS/debian"
printf 'Source: wirenhome-bridge\n\nPackage: wirenhome-bridge\nArchitecture: any\n' > "$SHLIBS/debian/control"
LIBDEPS="$(cd "$SHLIBS" && dpkg-shlibdeps -O "$ROOT/usr/bin/wirenhome-bridge" | sed -n 's/^shlibs:Depends=//p')"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: wirenhome-bridge
Version: $VERSION
Architecture: $ARCH
Maintainer: Andrey Lysikov
Section: misc
Priority: optional
Depends: $LIBDEPS, libavahi-compat-libdnssd1, avahi-daemon, qrencode
Description: Wiren Board to Apple Home bridge
 Publishes Wiren Board dashboards as HomeKit accessories.
EOF

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT/wirenhome-bridge_${VERSION}_${ARCH}.deb"
