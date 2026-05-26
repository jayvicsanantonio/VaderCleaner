# Vendor/

Holds prebuilt third-party binaries that ship inside `VaderCleaner.app`. The
contents are **not** checked into git — see `.gitignore`.

## clamav/

Produced by `Scripts/bundle-clamav.sh`. Populates:

```
Vendor/clamav/
  bin/{clamscan,freshclam}
  Frameworks/*.dylib       # libclamav + 8 dylib closure deps
  certs/clamav.crt         # root cert freshclam/libclamav use to verify CVD signatures
  LICENSES/                # GPL-2.0 (ClamAV) + courtesy includes
  .build-info              # bottle versions + sha256s used
```

The script:

1. Downloads `arm64_tahoe` Homebrew bottles for `clamav`, `openssl@3`, `pcre2`
   and `json-c` from `ghcr.io/v2/homebrew/core` and verifies their sha256
   against the metadata at `https://formulae.brew.sh/api/formula/<name>.json`.
2. Extracts only the binaries and dylibs we need (no headers, static libs,
   daemons, or share/ data).
3. Rewrites every `@@HOMEBREW_PREFIX@@/...` install name into `@rpath/...`
   via `install_name_tool`, adds two rpaths to the executables so they
   resolve dylibs whether run from inside `VaderCleaner.app` or from
   `Vendor/clamav/bin/` standalone, and ad-hoc-signs the result so Tahoe's
   dyld will load the rewritten binaries during local testing.
4. Verifies via `otool -L` that no Homebrew references survived.

`Scripts/stage-clamav.sh` then runs as an Xcode Run Script build phase and
rsyncs `Vendor/clamav/` into the built `.app` (`Frameworks/` and
`Resources/clamav/`), re-signing with the project's Developer ID identity.

## When to re-run `bundle-clamav.sh`

- New ClamAV release with a CVE fix.
- OpenSSL/PCRE2/json-c security update — `formulae.brew.sh` gets the new
  bottle within hours of the formula bump.
- Bumping `MACOSX_DEPLOYMENT_TARGET` — change `BOTTLE_TAG` at the top of
  the script (e.g. back to `arm64_sequoia` if you ever need to support
  macOS 15). If you drop below Sequoia, you'll also need an x86_64 pass
  and a final `lipo` step.

## GPL-2.0 obligation

ClamAV is GPL-2.0. Distributing the binaries from this directory inside
`VaderCleaner.app` triggers §3(b): we must offer the corresponding source
for three years. Practically:

1. Save the upstream tarball that matches the version in `.build-info`
   (`https://github.com/Cisco-Talos/clamav/releases/download/clamav-<version>/clamav-<version>.tar.gz`)
   somewhere we control (e.g. a GitHub release on this repo, or an S3
   bucket whose URL we won't break).
2. Surface that URL in the in-app About / Acknowledgements screen alongside
   the text from `LICENSES/LICENSE-clamav.txt`.

Calling `clamscan` as a subprocess (the way `ClamAVScanner.swift` does
today) keeps us on the "mere aggregation" side of the GPL — we are *not*
linking `libclamav` into the Swift app target. Do not change that.
