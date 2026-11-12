#!/usr/bin/env bash
# Build WatchBridge for macOS (universal binary: Apple Silicon + Intel).
# Mirrors scripts/Build-Windows.ps1: frontend build, Rust unit tests, Tauri
# bundle, license collection, BUILD.json provenance and SHA256SUMS.txt.
#
# Usage:
#   ./scripts/Build-MacOS.sh                 # checks only (frontend + tests)
#   ./scripts/Build-MacOS.sh --build-app     # also produce WatchBridge.dmg
#   ./scripts/Build-MacOS.sh --skip-tests    # skip the Rust unit tests
#   ./scripts/Build-MacOS.sh --offline       # no network (prepared caches)
set -euo pipefail

BUILD_APP=0
SKIP_TESTS=0
OFFLINE=0
for arg in "$@"; do
  case "$arg" in
    --build-app) BUILD_APP=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --offline) OFFLINE=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

run() { echo "+ $*"; "$@"; }
hash() { shasum -a 256 "$1" | awk '{print $1}'; }

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository"

for program in git bun cargo rustc python3; do
  command -v "$program" >/dev/null 2>&1 || { echo "Missing required program: $program" >&2; exit 1; }
done
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Use this script on macOS." >&2
  exit 1
fi

commit="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain)" ]; then dirty=true; else dirty=false; fi

artifacts="$repository/artifacts/macos"
mkdir -p "$artifacts"
# Clear only this helper's generated files, including results from failed runs.
# A checks-only run must never publish an older disk image as its own output.
for name in WatchBridge.dmg BUILD.json SHA256SUMS.txt LICENSES.zip; do
  rm -f "$artifacts/$name"
done

if [ "$OFFLINE" -eq 0 ]; then
  run bun install --frozen-lockfile --ignore-scripts
fi
run bun run build

cargo_options=(--locked --manifest-path src-tauri/Cargo.toml)
if [ "$OFFLINE" -eq 1 ]; then cargo_options+=(--offline); fi
if [ "$SKIP_TESTS" -eq 0 ]; then
  for package in iloader isideload; do
    run cargo test "${cargo_options[@]}" --lib -p "$package"
  done
fi

target_dir="$(cargo metadata "${cargo_options[@]}" --no-deps --format-version 1 \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')"

dmg_hash=""
if [ "$BUILD_APP" -eq 1 ]; then
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    if ! rustup target list --installed | grep -qx "$target"; then
      run rustup target add "$target"
    fi
  done
  tauri_args=(run tauri build --target universal-apple-darwin --config src-tauri/ci.conf.json -- --locked)
  if [ "$OFFLINE" -eq 1 ]; then tauri_args+=(--offline); fi
  run bun "${tauri_args[@]}"
  dmg_source="$(ls "$target_dir"/universal-apple-darwin/release/bundle/dmg/*.dmg | head -n 1)"
  cp "$dmg_source" "$artifacts/WatchBridge.dmg"
  dmg_hash="$(hash "$artifacts/WatchBridge.dmg")"
fi

run python3 scripts/Collect-Licenses.py --output "$artifacts/LICENSES.zip"

licenses_hash="$(hash "$artifacts/LICENSES.zip")"
if [ "$SKIP_TESTS" -eq 1 ]; then
  suites="not run (build-only)"
else
  suites="iloader and isideload unit tests passed"
fi
if [ "$BUILD_APP" -eq 1 ]; then
  executable_json="\"WatchBridge.dmg\""
  executable_hash_json="\"$dmg_hash\""
else
  executable_json="null"
  executable_hash_json="null"
fi

cat > "$artifacts/BUILD.json" <<EOF
{
  "completedUtc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sourceCommit": "$commit",
  "sourceDirty": $dirty,
  "platform": "macos-universal",
  "cargoLockSha256": "$(hash src-tauri/Cargo.lock)",
  "bunLockSha256": "$(hash bun.lock)",
  "rustVersion": "$(rustc --version)",
  "bunVersion": "$(bun --version)",
  "frontend": "passed",
  "physicallyValidated": false,
  "licenseReview": "pending-signing-dependency-clarification; see LICENSES.zip",
  "licensesSha256": "$licenses_hash",
  "rustSuites": "$suites",
  "executable": $executable_json,
  "executableSha256": $executable_hash_json
}
EOF

{
  echo "$(hash "$artifacts/BUILD.json")  BUILD.json"
  echo "$licenses_hash  LICENSES.zip"
  if [ "$BUILD_APP" -eq 1 ]; then echo "$dmg_hash  WatchBridge.dmg"; fi
} > "$artifacts/SHA256SUMS.txt"

echo "Build checks passed. Report: $artifacts/BUILD.json"
if [ "$BUILD_APP" -eq 1 ]; then
  echo "Disk image: $artifacts/WatchBridge.dmg (SHA-256: $dmg_hash)"
fi
