#!/bin/sh
# sign-dev.sh
# Ad-hoc code-signs the privileged helper and the app for local (unsigned)
# development builds, so SMAppService will register the helper and the
# Optimization actions can reach it. No-ops when a real signing identity is
# configured, leaving Developer ID / release signing untouched.

set -e

# Skip when a real signing identity is in use — release/distribution builds sign
# with Developer ID, and re-signing ad-hoc here would clobber that. Ad-hoc
# builds report an empty identity or the "-" sentinel.
if [ -n "${CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGN_IDENTITY}" != "-" ]; then
    echo "sign-dev: signing identity '${CODE_SIGN_IDENTITY}' in use — skipping ad-hoc signing."
    exit 0
fi

APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
HELPER="${APP}/Contents/MacOS/VaderCleanerHelper"

if [ ! -d "${APP}" ]; then
    echo "sign-dev: app bundle not found at ${APP}" >&2
    exit 1
fi
if [ ! -f "${HELPER}" ]; then
    echo "sign-dev: helper executable not found at ${HELPER}" >&2
    exit 1
fi

# Sign inside-out so sealing the app bundle doesn't trip over unsigned nested
# code. `--deep` is deliberately avoided: it would re-sign the helper with the
# wrong (default) identifier and break the XPC code-signing requirement.

# Auxiliary dylibs Xcode emits alongside the main executable in a debug build
# (the debug dylib and, with Previews enabled, __preview.dylib) are unsigned and
# must be signed before the bundle seal. The ClamAV dylibs in Contents/Frameworks
# are already signed by stage-clamav.sh.
for dylib in "${APP}/Contents/MacOS/"*.dylib; do
    [ -e "${dylib}" ] || continue
    echo "sign-dev: ad-hoc signing $(basename "${dylib}")"
    codesign --force --sign - "${dylib}"
done

# The helper is a command-line tool, whose default signing identifier is the
# executable name — pass its bundle identifier explicitly so it matches the
# code-signing requirement the helper enforces on the XPC connection.
echo "sign-dev: ad-hoc signing helper (com.personal.VaderCleaner.helper)"
codesign --force --sign - --identifier com.personal.VaderCleaner.helper "${HELPER}"

echo "sign-dev: ad-hoc signing app bundle"
codesign --force --sign - "${APP}"

echo "sign-dev: done."
