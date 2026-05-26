#!/usr/bin/env bash
# stage-clamav.sh
# Xcode Run Script build phase that copies Vendor/clamav/ into the built .app so the embedded clamscan binary and its dylibs ship inside the bundle.

set -euo pipefail

# -----------------------------------------------------------------------------
# Run from an Xcode "Run Script" build phase placed BEFORE the
# "Embed Frameworks" and code-signing phases. Xcode provides the variables
# we depend on (SRCROOT, BUILT_PRODUCTS_DIR, CONTENTS_FOLDER_PATH); when
# the script is invoked outside Xcode we synthesise sensible defaults so
# it can also be exercised from the command line during development.
# -----------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="${SRCROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
readonly VENDOR_DIR="${REPO_ROOT}/Vendor/clamav"

# When called from Xcode, ${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}
# already resolves to e.g. .../VaderCleaner.app/Contents — exactly the
# place we want to drop Frameworks/ and Resources/clamav/.
if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${CONTENTS_FOLDER_PATH:-}" ]]; then
    readonly CONTENTS_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}"
else
    echo "stage-clamav.sh: not running under Xcode; nothing to stage." >&2
    exit 0
fi

if [[ ! -d "${VENDOR_DIR}" ]]; then
    echo "error: ${VENDOR_DIR} is missing. Run Scripts/bundle-clamav.sh once to populate it." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Copy the binaries into Resources/clamav/bin/. We do NOT put clamscan in
# Contents/MacOS/ — that directory is reserved for the app's own executable
# and Apple's signing rules don't love secondary executables living there.
# -----------------------------------------------------------------------------
readonly RES_DIR="${CONTENTS_DIR}/Resources/clamav"
mkdir -p "${RES_DIR}/bin"
# -a preserves symlinks, mode bits, and timestamps; --delete keeps the
# destination in lockstep with Vendor/ so a removed file in Vendor really
# disappears from the .app on the next build.
rsync -a --delete "${VENDOR_DIR}/bin/"        "${RES_DIR}/bin/"
rsync -a --delete "${VENDOR_DIR}/certs/"      "${RES_DIR}/certs/"
rsync -a --delete "${VENDOR_DIR}/LICENSES/"   "${RES_DIR}/LICENSES/"

# -----------------------------------------------------------------------------
# Copy the dylibs into Contents/Frameworks/. Xcode's "Sign On Copy" /
# automatic embedded-framework signing only runs for items declared in
# Build Phases → Embed Frameworks, so the very last step here re-runs
# codesign for every dylib using the project's signing identity. That
# overwrites the ad-hoc signature bundle-clamav.sh applied locally and
# keeps notarization happy.
# -----------------------------------------------------------------------------
readonly FW_DIR="${CONTENTS_DIR}/Frameworks"
mkdir -p "${FW_DIR}"
rsync -a "${VENDOR_DIR}/Frameworks/" "${FW_DIR}/"

# Sign dylibs first, then executables — dyld rejects an executable
# whose dylib closure has invalid signatures. Executables also get the
# disable-library-validation entitlement so dyld lets them load sibling
# dylibs whose ad-hoc signatures don't share their Team ID (the default
# loader policy on macOS Tahoe).
#
# We sign on every build, not just when EXPANDED_CODE_SIGN_IDENTITY is
# set: a Debug build under CODE_SIGNING_ALLOWED=NO still needs the
# entitlement applied to clamscan/freshclam, otherwise spawning them
# via `Process` from the parent app dies with a Team ID mismatch.
readonly CLAMAV_ENTITLEMENTS="${SCRIPT_DIR}/clamav.entitlements"

if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    readonly SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY}"
    readonly SIGN_OPTS=(--options runtime --timestamp)
else
    readonly SIGN_IDENTITY="-"
    readonly SIGN_OPTS=(--timestamp=none)
fi

find "${FW_DIR}" -type f -name 'lib*.dylib' -print0 | \
    xargs -0 codesign --force "${SIGN_OPTS[@]}" --sign "${SIGN_IDENTITY}"
find "${RES_DIR}/bin" -type f -print0 | \
    xargs -0 codesign --force "${SIGN_OPTS[@]}" \
                      --entitlements "${CLAMAV_ENTITLEMENTS}" \
                      --sign "${SIGN_IDENTITY}"
