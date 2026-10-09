#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
.build/release/QingShot --shortcut-self-test
.build/release/QingShot --localization-self-test
QINGSHOT_TEST_OUTPUT="$PWD/.build" .build/release/QingShot --self-test
