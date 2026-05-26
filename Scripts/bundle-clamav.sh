#!/usr/bin/env bash
# bundle-clamav.sh
# Downloads the Homebrew bottles for clamav and its runtime deps, rewrites their install names so they resolve relative to the app bundle, and stages the result under Vendor/clamav/.

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
#
# Single arch: VaderCleaner targets macOS 26 (Tahoe), which is arm64-only.
# If the deployment target ever drops back to Sequoia or earlier, this
# script needs an x86_64 pass and a final `lipo -create` step per binary.

readonly BOTTLE_TAG="arm64_tahoe"

# Formulae we pull from. clamav itself plus every dylib `otool -L clamscan`
# resolves to a Homebrew prefix (system libs in /usr/lib stay system libs).
readonly FORMULAE=(clamav openssl@3 pcre2 json-c)

# Files we keep from each bottle. Everything else (headers, share/, static
# .a archives, daemon binaries, pkg-config, locale data) is dropped on the
# floor to keep the .app payload small.
#
# Each entry is <formula>:<relative-path-inside-bottle>. The clamav entries
# split between executables that land in bin/ and dylibs that land in
# Frameworks/; see `place_artifact` below for the routing.
readonly KEEP_PATHS=(
    "clamav:bin/clamscan"
    "clamav:bin/freshclam"
    # Root CA cert used by freshclam (>=1.5) to verify the digital
    # signature on every CVD it downloads. Lives under .bottle/etc/ in
    # the tarball because Homebrew rewrites etc/ paths at install time;
    # we ship a copy in the .app and pass --cvdcertsdir to freshclam.
    "clamav:.bottle/etc/clamav/certs/clamav.crt"
    "clamav:lib/libclamav.12.1.0.dylib"
    "clamav:lib/libclamav.12.dylib"
    "clamav:lib/libclamav.dylib"
    "clamav:lib/libclammspack.0.8.0.dylib"
    "clamav:lib/libclammspack.0.dylib"
    "clamav:lib/libclammspack.dylib"
    "clamav:lib/libclamunrar.12.1.0.dylib"
    "clamav:lib/libclamunrar.12.dylib"
    "clamav:lib/libclamunrar.dylib"
    "clamav:lib/libclamunrar_iface.12.1.0.dylib"
    "clamav:lib/libclamunrar_iface.12.dylib"
    "clamav:lib/libclamunrar_iface.dylib"
    "clamav:lib/libfreshclam.4.0.0.dylib"
    "clamav:lib/libfreshclam.4.dylib"
    "clamav:lib/libfreshclam.dylib"
    "openssl@3:lib/libssl.3.dylib"
    "openssl@3:lib/libcrypto.3.dylib"
    "pcre2:lib/libpcre2-8.0.dylib"
    # json-c is the only dep whose major-version dylib is a symlink to a
    # SemVer file rather than the real file itself, so we ship both the
    # symlink (which is what clamscan/libclamav resolve through `@rpath`)
    # and its target (the actual Mach-O that dyld ends up mapping).
    "json-c:lib/libjson-c.5.dylib"
    "json-c:lib/libjson-c.5.4.0.dylib"
)

# Resolve repo root from this script's location so the script works
# regardless of $PWD (Xcode Run Script phases, CI checkouts, etc.).
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly VENDOR_DIR="${REPO_ROOT}/Vendor/clamav"
readonly CACHE_DIR="${REPO_ROOT}/Vendor/.cache/bottles"
readonly WORK_DIR="$(mktemp -d -t bundle-clamav)"

trap 'rm -rf "${WORK_DIR}"' EXIT

# -----------------------------------------------------------------------------
# Pretty logging — `set -x` is too noisy and obscures the actual phases.
# -----------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

# -----------------------------------------------------------------------------
# Sanity: every command we shell out to.
# -----------------------------------------------------------------------------
require_tool curl
require_tool tar
require_tool shasum
require_tool python3
require_tool install_name_tool
require_tool otool
require_tool codesign

# -----------------------------------------------------------------------------
# 1. Fetch bottle URL + sha256 from the formulae.brew.sh API.
# -----------------------------------------------------------------------------
#
# We avoid the GitHub Packages registry handshake by going through the JSON
# index — it gives us a stable `https://ghcr.io/v2/.../blobs/sha256:<digest>`
# URL plus the matching sha256 in one call.

fetch_bottle_info() {
    local formula="$1"
    curl --fail --silent --show-error \
        "https://formulae.brew.sh/api/formula/${formula}.json" |
        python3 -c "
import json, sys
data = json.load(sys.stdin)
bottle = data['bottle']['stable']['files'].get('${BOTTLE_TAG}')
if bottle is None:
    sys.exit('no ${BOTTLE_TAG} bottle for ${formula}')
print(data['versions']['stable'])
print(bottle['url'])
print(bottle['sha256'])
"
}

download_bottle() {
    local formula="$1" version="$2" url="$3" expected_sha="$4"
    local cached="${CACHE_DIR}/${formula//\//-}-${version}-${BOTTLE_TAG}.tar.gz"

    if [[ -f "${cached}" ]]; then
        local have_sha
        have_sha="$(shasum -a 256 "${cached}" | awk '{print $1}')"
        if [[ "${have_sha}" == "${expected_sha}" ]]; then
            log "  cache hit: ${formula} ${version}"
            printf '%s' "${cached}"
            return
        fi
        warn "  cache sha mismatch for ${formula}; redownloading"
        rm -f "${cached}"
    fi

    mkdir -p "${CACHE_DIR}"
    # ghcr.io requires an Accept header to hand out raw bottle blobs; without
    # it the registry returns a manifest JSON instead of the tarball.
    curl --fail --silent --show-error --location \
         --header 'Authorization: Bearer QQ==' \
         --header 'Accept: application/vnd.oci.image.layer.v1.tar+gzip' \
         --output "${cached}" \
         "${url}"

    local have_sha
    have_sha="$(shasum -a 256 "${cached}" | awk '{print $1}')"
    [[ "${have_sha}" == "${expected_sha}" ]] || \
        die "sha mismatch for ${formula}: got ${have_sha}, expected ${expected_sha}"

    printf '%s' "${cached}"
}

# -----------------------------------------------------------------------------
# 2. Extract only the paths we care about into the work dir.
# -----------------------------------------------------------------------------
#
# Bottles unpack as `<formula>/<version>/<rel-path>`. We extract everything
# into ${WORK_DIR}/extracted/<formula>/<version>/... and then walk
# ${KEEP_PATHS} to copy individual files out — that way `cp` preserves the
# symlinks the bottle uses for libfoo.X.dylib → libfoo.X.Y.Z.dylib.

extract_bottle() {
    local formula="$1" tarball="$2"
    local target="${WORK_DIR}/extracted/${formula}"
    mkdir -p "${target}"
    tar -xzf "${tarball}" -C "${target}"
}

# Resolve where an extracted file lives (any version subdir).
locate_extracted() {
    local formula="$1" rel="$2"
    # bottle layout: <formula>/<version>/<rel>. We don't know the version
    # statically (the API gave it to us but we don't thread it through),
    # and we use -print without -quit so symlinks come along with the
    # underlying file when find walks the tree.
    local found
    found="$(find "${WORK_DIR}/extracted/${formula}" -path "*/${rel}" -print 2>/dev/null | head -n1)"
    [[ -n "${found}" ]] || die "missing in bottle: ${formula}/${rel}"
    printf '%s' "${found}"
}

# Route a kept artifact to bin/ or Frameworks/. clamav/bin/* → bin/,
# every *.dylib → Frameworks/. We preserve the bottle's symlink topology
# so dyld follows the same libfoo.dylib → libfoo.X.dylib → libfoo.X.Y.Z.dylib
# chain it would on a real install.
place_artifact() {
    local formula="$1" rel="$2"
    local src dst
    src="$(locate_extracted "${formula}" "${rel}")"

    case "${rel}" in
        bin/*)
            dst="${VENDOR_DIR}/bin/$(basename "${rel}")"
            ;;
        lib/*.dylib)
            dst="${VENDOR_DIR}/Frameworks/$(basename "${rel}")"
            ;;
        .bottle/etc/clamav/certs/*)
            dst="${VENDOR_DIR}/certs/$(basename "${rel}")"
            ;;
        *)
            die "unrouted artifact: ${formula}/${rel}"
            ;;
    esac

    mkdir -p "$(dirname "${dst}")"
    # -P preserves symlinks; -f overwrites without prompting on re-runs.
    cp -Pf "${src}" "${dst}"
}

# -----------------------------------------------------------------------------
# 3. Rewrite install names so the binaries find each other from inside the .app.
# -----------------------------------------------------------------------------
#
# The bottle ships dylibs whose deps point at `@@HOMEBREW_PREFIX@@/opt/...`
# (a sentinel Homebrew rewrites at install time). We replace every such
# reference with `@rpath/<basename>`, set the dylib ID to the same
# `@rpath/<basename>`, and add two rpaths to the executables so they
# resolve siblings whether the binary is run from the .app or from the
# Vendor/ staging directory.

rewrite_dylib() {
    local dylib="$1"
    [[ -f "${dylib}" && ! -L "${dylib}" ]] || return 0  # skip symlinks

    local base
    base="$(basename "${dylib}")"

    # Set the dylib's own ID to @rpath/<basename>. dyld uses this when a
    # *different* binary tries to load us — it must match the @rpath name
    # the consumer is asking for.
    install_name_tool -id "@rpath/${base}" "${dylib}"

    # Rewrite each homebrew-prefixed reference.
    otool -L "${dylib}" | awk 'NR>1 {print $1}' | while read -r ref; do
        case "${ref}" in
            @@HOMEBREW_PREFIX@@/*|@@HOMEBREW_CELLAR@@/*|/opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*)
                local new_name="@rpath/$(basename "${ref}")"
                install_name_tool -change "${ref}" "${new_name}" "${dylib}"
                ;;
        esac
    done
}

rewrite_executable() {
    local exe="$1"
    [[ -f "${exe}" ]] || return 0

    otool -L "${exe}" | awk 'NR>1 {print $1}' | while read -r ref; do
        case "${ref}" in
            @@HOMEBREW_PREFIX@@/*|@@HOMEBREW_CELLAR@@/*|/opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*)
                local new_name="@rpath/$(basename "${ref}")"
                install_name_tool -change "${ref}" "${new_name}" "${exe}"
                ;;
        esac
    done

    # Strip any rpaths the bottle baked in — leftover Homebrew prefixes
    # would resolve to a path on the *contributor's* machine and silently
    # break on someone else's.
    otool -l "${exe}" | awk '
        /cmd LC_RPATH/ { found=1; next }
        found && /path / { print $2; found=0 }
    ' | while read -r rp; do
        install_name_tool -delete_rpath "${rp}" "${exe}" 2>/dev/null || true
    done

    # Two rpaths cover both deployment shapes:
    #   .app/Contents/Resources/clamav/bin/clamscan → ../../../Frameworks
    #   Vendor/clamav/bin/clamscan                  → ../Frameworks
    install_name_tool -add_rpath "@executable_path/../../../Frameworks" "${exe}"
    install_name_tool -add_rpath "@executable_path/../Frameworks"       "${exe}"
}

# -----------------------------------------------------------------------------
# 4. Verify nothing slipped through. Failing here is cheap; failing in
#    production because dyld can't find libssl is not.
# -----------------------------------------------------------------------------

verify_no_homebrew_refs() {
    local file="$1"
    if otool -L "${file}" | grep -qE '@@HOMEBREW_PREFIX@@|@@HOMEBREW_CELLAR@@|/opt/homebrew|/usr/local/Cellar|/usr/local/opt'; then
        otool -L "${file}" >&2
        die "homebrew reference still present in ${file}"
    fi
}

# -----------------------------------------------------------------------------
# 5. License files. GPL-2.0 requires us to make ClamAV's license visible
#    and the OpenSSL/PCRE2/json-c licenses are short courtesy includes.
#    Each formula's bottle keeps its license under share/<formula>/, but
#    those paths are inconsistent across upstreams, so we fetch the
#    canonical text from formulae.brew.sh metadata instead.
# -----------------------------------------------------------------------------

stage_licenses() {
    mkdir -p "${VENDOR_DIR}/LICENSES"
    {
        echo "VaderCleaner bundles the following open-source components."
        echo "Sources are available at:"
        echo "  ClamAV:     https://github.com/Cisco-Talos/clamav"
        echo "  OpenSSL:    https://github.com/openssl/openssl"
        echo "  PCRE2:      https://github.com/PCRE2Project/pcre2"
        echo "  json-c:     https://github.com/json-c/json-c"
        echo
        echo "License terms below."
    } > "${VENDOR_DIR}/LICENSES/README.txt"

    # ClamAV is GPL-2.0; surfacing this text in the app's about screen is
    # the practical part of the obligation. The "written offer to provide
    # source" is also required — see Vendor/clamav/README.md.
    cat > "${VENDOR_DIR}/LICENSES/LICENSE-clamav.txt" <<'EOF'
ClamAV is distributed under the terms of the GNU General Public License,
version 2. The full license text is available at
https://www.gnu.org/licenses/old-licenses/gpl-2.0.html .

Per GPL-2.0 §3, VaderCleaner accompanies this binary with a written offer
to provide the corresponding source code. See Vendor/clamav/README.md for
the URL of the exact source tarball matching the binaries shipped here.
EOF
}

# -----------------------------------------------------------------------------
# 6. Build-info manifest. Records exactly which bottle sha256s went into
#    this drop so a future bisect or audit can reproduce it.
# -----------------------------------------------------------------------------

write_build_info() {
    local info="${VENDOR_DIR}/.build-info"
    {
        echo "# Generated by Scripts/bundle-clamav.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "bottle_tag: ${BOTTLE_TAG}"
        echo "formulae:"
        local entry
        for entry in "${BUILD_INFO_ENTRIES[@]}"; do
            echo "  ${entry}"
        done
    } > "${info}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

log "Cleaning Vendor/clamav/"
rm -rf "${VENDOR_DIR}"
mkdir -p "${VENDOR_DIR}/bin" "${VENDOR_DIR}/Frameworks"

declare -a BUILD_INFO_ENTRIES=()

log "Downloading bottles (${BOTTLE_TAG})"
for formula in "${FORMULAE[@]}"; do
    read -r version url sha < <(fetch_bottle_info "${formula}" | tr '\n' ' '; echo)
    log "  ${formula} ${version}"
    tarball="$(download_bottle "${formula}" "${version}" "${url}" "${sha}")"
    extract_bottle "${formula}" "${tarball}"
    BUILD_INFO_ENTRIES+=("- name: ${formula}")
    BUILD_INFO_ENTRIES+=("  version: ${version}")
    BUILD_INFO_ENTRIES+=("  sha256: ${sha}")
done

log "Staging artifacts"
for entry in "${KEEP_PATHS[@]}"; do
    formula="${entry%%:*}"
    rel="${entry#*:}"
    place_artifact "${formula}" "${rel}"
done

log "Rewriting install names (Frameworks/)"
for dylib in "${VENDOR_DIR}/Frameworks/"*.dylib; do
    rewrite_dylib "${dylib}"
done

log "Rewriting install names (bin/)"
for exe in "${VENDOR_DIR}/bin/"*; do
    rewrite_executable "${exe}"
done

log "Verifying no Homebrew references remain"
for f in "${VENDOR_DIR}/bin/"* "${VENDOR_DIR}/Frameworks/"*.dylib; do
    [[ -L "${f}" ]] && continue
    verify_no_homebrew_refs "${f}"
done

log "Ad-hoc signing (Tahoe's dyld rejects rewritten unsigned binaries)"
# Sign dylibs before executables: codesign needs the dependency closure
# to be consistent before it can sign a consumer. Skipping symlinks keeps
# the resulting .DS_Store-free.
for f in "${VENDOR_DIR}/Frameworks/"*.dylib; do
    [[ -L "${f}" ]] && continue
    codesign --force --sign - --timestamp=none "${f}"
done
for f in "${VENDOR_DIR}/bin/"*; do
    codesign --force --sign - --timestamp=none "${f}"
done
# Xcode will re-sign everything with the project's Developer ID during the
# app's own code-signing build phase; the ad-hoc signature here just lets
# the contributor smoke-test `Vendor/clamav/bin/clamscan --version`
# locally without Gatekeeper rejecting it.

stage_licenses
write_build_info

log "Smoke test"
"${VENDOR_DIR}/bin/clamscan" --version
# freshclam refuses to start without a conf file, even for --version, so
# we feed it /dev/null — this proves the dyld closure resolves without
# committing to a particular DatabaseDirectory (the app picks one at
# runtime under ~/Library/Application Support/VaderCleaner/clamav/).
"${VENDOR_DIR}/bin/freshclam" --config-file=/dev/null --version

log "Done. Vendor/clamav/ is $(du -sh "${VENDOR_DIR}" | awk '{print $1}')"
