#!/bin/bash
# Builds the ALVR client core for visionOS, repacks it into ALVRClientCore.xcframework, and
# optionally builds or installs the app. A friendlier version of build_and_repack.sh: it does not
# wipe the Rust target directory on every run, and it checks the toolchain before spending minutes
# on a build that cannot succeed.
#
#   ./build_ar_mode.sh            core + xcframework + app build
#   ./build_ar_mode.sh core       only the Rust core and the xcframework
#   ./build_ar_mode.sh app        only the Xcode build
#   ./build_ar_mode.sh install    everything, then install on a connected Vision Pro
#
#   CLEAN=1 ./build_ar_mode.sh            wipe ALVR/target first
#   CONFIG=Release ./build_ar_mode.sh     Release instead of Debug
#   DEVICE_UDID=... ./build_ar_mode.sh install
#
# See AR_MODE_HANDOFF.md for the signing and sideloading steps this does not automate.
set -euo pipefail

cd "$(dirname "$0")"

STAGE="${1:-all}"
CONFIG="${CONFIG:-Debug}"
MIN_RUST="1.92"
APP_DIR="build/Build/Products/$CONFIG-xros/ALVRClient.app"

step() { printf '\n==> %s\n' "$1"; }
die() { printf '\nerror: %s\n' "$1" >&2; exit 1; }

build_core() {
    [ -f ALVR/Cargo.toml ] || {
        step "Submodule missing, initializing"
        git submodule update --init --recursive
    }
    [ -f ALVR/Cargo.toml ] || die "ALVR/Cargo.toml still missing after submodule update"

    command -v cargo >/dev/null || die "cargo not found. Install Rust: https://rustup.rs"

    # The workspace is edition 2024 and declares rust-version = 1.92.
    rust_version="$(rustc --version | awk '{print $2}')"
    if ! awk -v have="$rust_version" -v need="$MIN_RUST" '
        BEGIN {
            split(have, h, /[.-]/); split(need, n, ".");
            exit !(h[1] > n[1] || (h[1] == n[1] && h[2] >= n[2]));
        }'; then
        die "Rust $rust_version is too old, need $MIN_RUST or newer. Run: rustup update stable"
    fi

    xcrun --version >/dev/null 2>&1 || die "Xcode command line tools not found. Run: xcode-select --install"

    step "Toolchain: rustc $rust_version, $(xcodebuild -version | head -1)"

    if command -v rustup >/dev/null; then
        rustup target add aarch64-apple-ios
    else
        echo "  rustup not found, assuming the aarch64-apple-ios standard library is installed"
    fi
    command -v cbindgen >/dev/null || {
        step "Installing cbindgen"
        cargo install cbindgen
    }

    if [ -n "${CLEAN:-}" ]; then
        step "Cleaning ALVR/target"
        rm -rf ALVR/target ALVR/build
    fi

    # Xcode exports SDKROOT when it invokes scripts, which makes cargo build against the wrong SDK.
    unset SDKROOT

    step "Building alvr_client_core for aarch64-apple-ios"
    CARGO_TARGET_DIR=ALVR/target cargo build \
        --manifest-path ALVR/Cargo.toml \
        --target=aarch64-apple-ios \
        -p alvr_client_core \
        --profile distribution

    step "Generating alvr_client_core.h"
    mkdir -p ALVR/build
    (cd ALVR/alvr/client_core && cbindgen --config cbindgen.toml --crate alvr_client_core \
        --output ../../build/alvr_client_core.h)

    # Names this port assumes. A mismatch here is the most likely cause of Swift build errors.
    step "Checking the generated C API surface"
    for symbol in ALVR_CODEC_TYPE_HEVC ALVR_VIDEO_STREAM_KIND_ALPHA \
                  alvr_get_alpha_decoder_config alvr_set_alpha_decoder_input_callback \
                  alvr_send_tracking_and_face_data; do
        if grep -q "$symbol" ALVR/build/alvr_client_core.h; then
            echo "  ok      $symbol"
        else
            echo "  MISSING $symbol  <- the Swift side expects this name"
        fi
    done

    step "Repacking ALVRClientCore.xcframework"
    sh repack_alvr_client.sh
}

build_app() {
    [ -d ALVRClient/ALVRClientCore.xcframework ] || die "ALVRClientCore.xcframework missing. Run: ./build_ar_mode.sh core"

    step "Building ALVRClient ($CONFIG) for visionOS"
    xcodebuild -project ALVRClient.xcodeproj \
        -scheme ALVRClient \
        -configuration "$CONFIG" \
        -destination 'generic/platform=visionOS' \
        -derivedDataPath build \
        build

    [ -d "$APP_DIR" ] && step "Built $APP_DIR"
}

install_app() {
    [ -d "$APP_DIR" ] || die "$APP_DIR not found, build first"

    if [ -z "${DEVICE_UDID:-}" ]; then
        printf '\nSet DEVICE_UDID to one of the identifiers below and run again:\n\n'
        xcrun devicectl list devices || true
        exit 1
    fi

    step "Installing on $DEVICE_UDID"
    xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_DIR"
}

case "$STAGE" in
    core)    build_core ;;
    app)     build_app ;;
    install) build_core; build_app; install_app ;;
    all)     build_core; build_app ;;
    *)       die "unknown stage '$STAGE'. Use: core | app | install | all" ;;
esac

step "Done"
