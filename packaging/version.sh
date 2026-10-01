#!/bin/bash
#  Copyright © AndreyLysikov
#  SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Prints the app version from Version.swift, fails unless it is two numbers.
FILE="$(cd "$(dirname "$0")/.." && pwd)/Sources/WirenHome/Version.swift"
VERSION="$(sed -nE 's/.*static let current = "([^"]*)".*/\1/p' "$FILE")"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "Version in $FILE must be two numbers, like 0.1, not '$VERSION'" >&2
    exit 1
fi
echo "$VERSION"
