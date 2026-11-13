#!/bin/bash
# Builds the app bundle, then runs the end-to-end suite against it.
# The tests put real rest overlays on screen for a few seconds at a time.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-debug} ARCHS=${ARCHS:-$(uname -m)} scripts/build-app.sh
SOFTFOCUS_APP="$PWD/build/Softfocus.app" swift test --filter SoftfocusE2ETests "$@"
