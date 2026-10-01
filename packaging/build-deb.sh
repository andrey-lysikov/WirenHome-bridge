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
ROOT="$(mktemp -d)/wb-homekit"

install -D -m 0755 "$BINARY" "$ROOT/usr/bin/wb-homekit"
install -D -m 0644 "$HERE/wb-homekit.service" "$ROOT/lib/systemd/system/wb-homekit.service"
install -D -m 0644 "$HERE/../LICENSE" "$ROOT/usr/share/doc/wb-homekit/copyright"
install -D -m 0644 "$HERE/wb-homekit.conf" "$ROOT/etc/wb-homekit.conf"
install -D -m 0644 "$HERE/wb-homekit.schema.json" "$ROOT/usr/share/wb-mqtt-confed/schemas/wb-homekit.schema.json"
for script in postinst prerm postrm; do
    install -D -m 0755 "$HERE/$script" "$ROOT/DEBIAN/$script"
done
echo "/etc/wb-homekit.conf" > "$ROOT/DEBIAN/conffiles"

# Updates come from the project's signed apt repository once its public key is in the tree.
if [ -f "$HERE/wb-homekit.gpg" ]; then
    install -D -m 0644 "$HERE/wb-homekit.gpg" "$ROOT/usr/share/keyrings/wb-homekit.gpg"
    install -D -m 0644 "$HERE/wb-homekit.list" "$ROOT/etc/apt/sources.list.d/wb-homekit.list"
    echo "/etc/apt/sources.list.d/wb-homekit.list" >> "$ROOT/DEBIAN/conffiles"
else
    echo "warning: packaging/wb-homekit.gpg is missing, the package will not receive apt updates" >&2
fi

# dpkg-shlibdeps needs a debian/control to run, so give it a throwaway one.
SHLIBS="$(mktemp -d)"
mkdir -p "$SHLIBS/debian"
printf 'Source: wb-homekit\n\nPackage: wb-homekit\nArchitecture: any\n' > "$SHLIBS/debian/control"
LIBDEPS="$(cd "$SHLIBS" && dpkg-shlibdeps -O "$ROOT/usr/bin/wb-homekit" | sed -n 's/^shlibs:Depends=//p')"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: wb-homekit
Version: $VERSION
Architecture: $ARCH
Maintainer: Andrey Lysikov
Section: misc
Priority: optional
Depends: $LIBDEPS, libavahi-compat-libdnssd1, avahi-daemon
Description: Wiren Board to Apple Home bridge
 Publishes Wiren Board dashboards as HomeKit accessories.
EOF

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT/wb-homekit_${VERSION}_${ARCH}.deb"
