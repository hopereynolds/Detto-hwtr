#!/usr/bin/env bash
set -euo pipefail

# Build and install "Detto HWTR", Hope's fork, next to Detto.
#
# It has its own bundle ID, so it keeps its own settings, logs, session files
# and temp audio, and never replaces /Applications/Detto.app. It's signed with
# a local certificate (see setup_local_signing.sh) so macOS remembers its
# Microphone and Screen Recording permissions across rebuilds.
#
# Usage: ./scripts/build_hwtr.sh

cd "$(dirname "$0")"

export APP_NAME="Detto HWTR"
# Neutral on purpose: the display name may change, the bundle ID must not
# (permissions and settings are tied to it).
export BUNDLE_ID="io.github.hopereynolds.detto"
# Default transcript folder (~/Documents/<name>). Keep it fixed even if
# APP_NAME changes, so new notes don't move.
export DOCUMENTS_FOLDER_NAME="Detto HWTR"
export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Detto HWTR Local Signing}"
export DISABLE_LIBRARY_VALIDATION=1

if ! security find-identity -p codesigning | grep -Fq "\"$CODESIGN_IDENTITY\""; then
  echo "Signing certificate \"$CODESIGN_IDENTITY\" not found. Creating it..."
  ./setup_local_signing.sh "$CODESIGN_IDENTITY"
fi

exec ./build_swift_app.sh
