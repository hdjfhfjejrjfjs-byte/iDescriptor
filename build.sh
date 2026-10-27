#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

# Cargo may redirect its output directory; honor it instead of assuming target/.
TARGET_DIR="${CARGO_TARGET_DIR:-target}"
case "${TARGET_DIR}" in
    /*) ;;
    *) TARGET_DIR="${ROOT}/${TARGET_DIR}" ;;
esac
STATIC_QT_ROOT="${ROOT}/.cache/macos-static/qt6"
STATIC_QT_MARKER="${STATIC_QT_ROOT}/.build-info"
BREW_PREFIX=""
GST_QML6_PLUGIN=""

QT_FORMULAE=(
    qtbase
    qtdeclarative
    qtsvg
    qtshadertools
    qttools
    qtmultimedia
    qtlocation
    qtpositioning
    qtquicktimeline
    qtserialport
    qt5compat
)

log() { printf 'build.sh: %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

prepend_path() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 0
    case ":${PATH}:" in
        *":${dir}:"*) ;;
        *) export PATH="${dir}:${PATH}" ;;
    esac
}

canonical_formula() {
    case "$1" in
        gst-libav | gst-plugins-base | gst-plugins-good | gst-plugins-bad | gst-plugins-ugly)
            printf '%s\n' gstreamer
            ;;
        pkg-config | pkgconfig)
            printf '%s\n' pkgconf
            ;;
        openssl)
            printf '%s\n' openssl@3
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

ensure_macos() {
    [[ "$(uname -s)" == Darwin ]] || die "this helper is macOS-only"
}

ensure_xcode() {
    if xcode-select -p >/dev/null 2>&1; then
        # Pin SDKROOT to the SDK belonging to the selected Xcode/CLT. Without it
        # clang may pick a mismatched CommandLineTools SDK whose stubs the
        # active linker cannot parse (e.g. arm64e.x1-* targets in libSystem).
        local sdk
        sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
        if [[ -n "${sdk}" && -d "${sdk}" ]]; then
            export SDKROOT="${SDKROOT:-${sdk}}"
        fi
        return 0
    fi
    die "Xcode Command Line Tools are missing; run: xcode-select --install"
}

ensure_submodules() {
    [[ -f "${ROOT}/.gitmodules" ]] || return 0
    # lib/idevice-rs is a submodule and Cargo.toml patches `idevice` to it.
    git -C "${ROOT}" submodule update --init --recursive
}

activate_homebrew() {
    local brew_bin="$1"
    local brew_prefix
    brew_prefix="$("${brew_bin}" --prefix)"
    prepend_path "${brew_prefix}/bin"
    prepend_path "${brew_prefix}/sbin"
    export HOMEBREW_PREFIX="${brew_prefix}"
    export HOMEBREW_CELLAR="${brew_prefix}/Cellar"
    BREW_PREFIX="${brew_prefix}"
}

ensure_homebrew() {
    local brew_bin
    if command -v brew >/dev/null 2>&1; then
        activate_homebrew "$(command -v brew)"
        return 0
    fi

    for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "${brew_bin}" ]]; then
            activate_homebrew "${brew_bin}"
            return 0
        fi
    done

    die "Homebrew is required (https://brew.sh). Install it, then re-run ./build.sh"
}

formula_installed() {
    brew list --formula --versions "$1" >/dev/null 2>&1
}

ensure_brew_deps() {
    local -a wanted=(
        autoconf
        automake
        cmake
        ninja
        pkgconf
        openssl@3
        ffmpeg
        libheif
        libplist
        meson
        gstreamer
        jpeg-xl
        sqlite
        "${QT_FORMULAE[@]}"
    )
    local -a missing=()
    local -a broken=()
    local dep canonical already queued prefix
    for dep in "${wanted[@]}"; do
        canonical="$(canonical_formula "${dep}")"
        already=0
        for queued in "${missing[@]+"${missing[@]}"}" "${broken[@]+"${broken[@]}"}"; do
            if [[ "${queued}" == "${canonical}" ]]; then
                already=1
                break
            fi
        done
        if [[ "${already}" -eq 1 ]]; then
            continue
        fi
        if formula_installed "${canonical}"; then
            # brew can still list a formula whose Cellar tree was removed; detect
            # that and repair it instead of failing later at link time.
            prefix="$(brew --prefix "${canonical}" 2>/dev/null || true)"
            if [[ -z "${prefix}" || ! -d "${prefix}" ]]; then
                broken+=("${canonical}")
            fi
        else
            missing+=("${canonical}")
        fi
    done

    if ((${#missing[@]})); then
        log "brew install ${missing[*]}"
        brew install "${missing[@]}"
    fi
    if ((${#broken[@]})); then
        log "brew reinstall (missing prefix): ${broken[*]}"
        brew reinstall "${broken[@]}"
    fi
}

version_num() {
    awk -F. -v v="${1:-0.0.0}" 'BEGIN {
        n = split(v, a, /[.-]/)
        printf "%d%03d%03d\n", a[1]+0, a[2]+0, (n >= 3 ? a[3]+0 : 0)
    }'
}

rustc_version_num() {
    version_num "$("$@" --version 2>/dev/null | awk '{print $2}')"
}

ensure_rust() {
    # kstring 2.0.4 (pulled by current Cargo.lock) needs rustc 1.96+.
    local min_rustc="1.96.0"
    local min_num current_num stable_num

    prepend_path "${HOME}/.cargo/bin"
    if [[ -f "${HOME}/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "${HOME}/.cargo/env"
    fi

    if ! command -v rustup >/dev/null 2>&1; then
        log "installing rustup (stable)"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path --default-toolchain stable
        prepend_path "${HOME}/.cargo/bin"
        if [[ -f "${HOME}/.cargo/env" ]]; then
            # shellcheck disable=SC1091
            source "${HOME}/.cargo/env"
        fi
    fi

    command -v rustup >/dev/null 2>&1 || die "rustup is missing after install"

    min_num="$(version_num "${min_rustc}")"
    current_num=0
    if command -v rustc >/dev/null 2>&1; then
        current_num="$(rustc_version_num rustc)"
    fi

    if [[ "${current_num}" -lt "${min_num}" ]]; then
        log "rustc is too old for this tree (need >= ${min_rustc}); installing stable"
        rustup toolchain install stable
        rustup update stable
        rustup override set stable
        export RUSTUP_TOOLCHAIN=stable
        prepend_path "${HOME}/.cargo/bin"
    fi

    command -v cargo >/dev/null 2>&1 || die "cargo still not found after rustup setup"
    current_num="$(rustc_version_num rustc)"
    if [[ "${current_num}" -lt "${min_num}" ]]; then
        stable_num="$(rustc_version_num rustup run stable rustc)"
        if [[ "${stable_num}" -ge "${min_num}" ]]; then
            rustup override set stable
            export RUSTUP_TOOLCHAIN=stable
        else
            die "rustc $(rustc --version) is still older than ${min_rustc}"
        fi
    fi

    log "rustc $(rustc --version)"
    log "cargo $(cargo --version)"
}

ensure_qt_env() {
    local formula prefix
    QT_PREFIXES=()

    for formula in "${QT_FORMULAE[@]}"; do
        prefix="$(brew --prefix "${formula}")"
        [[ -d "${prefix}" ]] || die "missing ${formula} at ${prefix}"
        QT_PREFIXES+=("${prefix}")
    done

    QTBASE_PREFIX="$(brew --prefix qtbase)"
    if [[ -z "${QMAKE:-}" ]]; then
        if [[ -x "${QTBASE_PREFIX}/bin/qmake" ]]; then
            export QMAKE="${QTBASE_PREFIX}/bin/qmake"
        elif [[ -x "${QTBASE_PREFIX}/bin/qmake6" ]]; then
            export QMAKE="${QTBASE_PREFIX}/bin/qmake6"
        else
            die "qmake not found under ${QTBASE_PREFIX}/bin"
        fi
    fi

    prepend_path "$(dirname "${QMAKE}")"
    export CMAKE_PREFIX_PATH="$(IFS=:; echo "${QT_PREFIXES[*]}")${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
}

ensure_pkg_config_path() {
    local brew_prefix formula prefix
    brew_prefix="$(brew --prefix)"
    export PKG_CONFIG_PATH="${brew_prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

    for formula in openssl@3 sqlite; do
        prefix="$(brew --prefix "${formula}" 2>/dev/null || true)"
        if [[ -d "${prefix}/lib/pkgconfig" ]]; then
            export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig:${PKG_CONFIG_PATH}"
        fi
    done

    command -v pkg-config >/dev/null 2>&1 || command -v pkgconf >/dev/null 2>&1 \
        || die "pkg-config/pkgconf is missing"
}

ensure_ninja_generator() {
    command -v ninja >/dev/null 2>&1 || die "ninja is required but not found"
    export CMAKE_GENERATOR="Ninja"
    log "using Ninja generator for CMake (fast incremental builds)"
}

# Print absolute paths under the active Homebrew prefix that a build graph or
# cache still references even though Homebrew removed them (usually because
# `brew upgrade` replaced a Cellar revision). The prefix comes from the live
# Homebrew installation, so no version or install path is hardcoded.
stale_brew_refs() {
    local file token
    [[ -n "${BREW_PREFIX}" ]] || return 0
    for file in "$@"; do
        [[ -f "${file}" ]] || continue
        while IFS= read -r token; do
            case "${token}" in
                -isystem*) token="${token#-isystem}" ;;
                -iframework*) token="${token#-iframework}" ;;
                -I*) token="${token#-I}" ;;
                -L*) token="${token#-L}" ;;
                -F*) token="${token#-F}" ;;
            esac
            case "${token}" in
                "${BREW_PREFIX}"/*) ;;
                *) continue ;;
            esac
            [[ -e "${token}" ]] || printf '%s\n' "${token}"
        done < <(tr " \t\n\"';:,()<>=\\" "\n" < "${file}")
    done | sort -u
}

# Reinstall Homebrew formulae whose tree vanished entirely. Paths that merely
# moved to a new Cellar revision are left alone; the caller regenerates the
# graph that referenced them.
repair_brew_missing_refs() {
    local path rel formula queued seen
    local -a pending=()
    local -a unique=()

    for path in "$@"; do
        case "${path}" in
            "${BREW_PREFIX}"/Cellar/*) rel="${path#"${BREW_PREFIX}"/Cellar/}" ;;
            "${BREW_PREFIX}"/opt/*) rel="${path#"${BREW_PREFIX}"/opt/}" ;;
            *) continue ;;
        esac
        formula="${rel%%/*}"
        [[ -n "${formula}" ]] || continue
        if [[ ! -d "${BREW_PREFIX}/Cellar/${formula}" && ! -d "${BREW_PREFIX}/opt/${formula}" ]]; then
            pending+=("${formula}")
        fi
    done

    ((${#pending[@]})) || return 0
    for formula in "${pending[@]}"; do
        seen=0
        for queued in "${unique[@]+"${unique[@]}"}"; do
            if [[ "${queued}" == "${formula}" ]]; then
                seen=1
                break
            fi
        done
        if [[ "${seen}" -eq 0 ]]; then
            unique+=("${formula}")
        fi
    done

    log "reinstalling broken Homebrew formula(s): ${unique[*]}"
    brew reinstall "${unique[@]}"
}

# Cargo build-script outputs and any CMake caches can pin absolute Homebrew
# paths; drop them so the next build re-probes the current environment.
drop_stale_build_caches() {
    local cache graph dir file line
    local -a stale_paths=()

    for cache in "${TARGET_DIR}"/*/build/*/out/build/CMakeCache.txt; do
        [[ -f "${cache}" ]] || continue
        graph="${cache%/*}/build.ninja"
        stale_paths=()
        while IFS= read -r line; do
            [[ -n "${line}" ]] && stale_paths+=("${line}")
        done < <(stale_brew_refs "${cache}" "${graph}")
        if ((${#stale_paths[@]})) || grep -Eq '_DIR:PATH=[^=]*-NOTFOUND' "${cache}"; then
            log "dropping stale CMake cache (${cache})"
            repair_brew_missing_refs "${stale_paths[@]+"${stale_paths[@]}"}"
            rm -rf "$(dirname "$(dirname "${cache}")")"
        fi
    done

    for dir in "${TARGET_DIR}"/*/build/idescriptor-*/; do
        [[ -d "${dir}" ]] || continue
        while IFS= read -r file; do
            if [[ -n "$(stale_brew_refs "${file}")" ]]; then
                log "dropping stale build-script output (${dir})"
                rm -rf "${dir}"
                break
            fi
        done < <(find "${dir}" -type f \( -name '*.d' -o -name 'output' \) 2>/dev/null)
    done
}

ensure_gst_qml6() {
    local version archive source_url srcdir builddir prefix_dir definition line
    local reconfigure
    local -a stale_paths=()
    local -a missing_paths=()
    local -a setup_flags=()

    command -v meson >/dev/null 2>&1 || die "meson is missing"
    command -v ninja >/dev/null 2>&1 || die "ninja is missing"
    command -v pkg-config >/dev/null 2>&1 || die "pkg-config is missing"

    if ! pkg-config --exists gstreamer-1.0 gstreamer-gl-1.0; then
        log "pkg-config cannot resolve GStreamer development files; reinstalling gstreamer"
        brew reinstall gstreamer
        pkg-config --exists gstreamer-1.0 gstreamer-gl-1.0 \
            || die "GStreamer development files are still missing after reinstall"
    fi

    version="$(pkg-config --modversion gstreamer-1.0 2>/dev/null || true)"
    [[ -n "${version}" ]] || die "could not read gstreamer-1.0 version from pkg-config"

    GST_QML6_ROOT="${TARGET_DIR}/gst-qml6-${version}"
    srcdir="${GST_QML6_ROOT}/gst-plugins-good-${version}"
    builddir="${srcdir}/build-qml6"
    prefix_dir="${GST_QML6_ROOT}/prefix"
    GST_QML6_PLUGIN="${builddir}/ext/qt6/libgstqml6.dylib"

    mkdir -p "${GST_QML6_ROOT}"
    archive="gst-plugins-good-${version}.tar.xz"
    source_url="https://gstreamer.freedesktop.org/src/gst-plugins-good/${archive}"

    if [[ ! -f "${GST_QML6_ROOT}/${archive}.sha256sum" ]]; then
        log "downloading ${archive}.sha256sum"
        curl --fail --location --retry 3 --output "${GST_QML6_ROOT}/${archive}.sha256sum" "${source_url}.sha256sum"
    fi

    if [[ ! -f "${GST_QML6_ROOT}/${archive}" ]] \
        || ! (cd "${GST_QML6_ROOT}" && shasum -a 256 --check --status "${archive}.sha256sum"); then
        log "downloading ${archive}"
        curl --fail --location --retry 3 --output "${GST_QML6_ROOT}/${archive}" "${source_url}"
        (cd "${GST_QML6_ROOT}" && shasum -a 256 --check "${archive}.sha256sum") \
            || die "checksum verification failed for ${archive}"
    fi

    if [[ ! -f "${srcdir}/meson.build" ]]; then
        rm -rf "${srcdir}"
        tar -xf "${GST_QML6_ROOT}/${archive}" -C "${GST_QML6_ROOT}"
        [[ -f "${srcdir}/meson.build" ]] || die "failed to extract ${archive}"
    fi

    # Keep qml6 out of Homebrew's GStreamer prefix so `brew upgrade` cannot wipe it.
    # Keep the build dir too: deleting it throws away every object file and turns a
    # 1-line change into a full gst-plugins-good rebuild.
    setup_flags=(
        --prefix="${prefix_dir}"
        --libdir=lib
        --auto-features=disabled
        -Dqt-method=qmake
        -Dqt6=enabled
        -Dqt5=disabled
        -Dtests=disabled
        -Dexamples=disabled
        -Dnls=disabled
    )

    if [[ -f "${builddir}/build.ninja" ]]; then
        while IFS= read -r line; do
            if [[ -n "${line}" ]]; then
                stale_paths+=("${line}")
            fi
        done < <(stale_brew_refs "${builddir}/build.ninja")
    fi

    if [[ ! -f "${builddir}/build.ninja" ]]; then
        log "meson setup qml6glsink (prefix=${prefix_dir})"
        meson setup "${builddir}" "${srcdir}" "${setup_flags[@]}"
    elif ((${#stale_paths[@]})); then
        # Meson caches pkg-config results, so --reconfigure keeps pointing at
        # revisions Homebrew already deleted. Wipe and re-probe instead.
        log "qml6 build dir references ${#stale_paths[@]} path(s) that Homebrew removed; rebuilding it"
        repair_brew_missing_refs "${stale_paths[@]}"
        rm -rf "${builddir}"
        meson setup "${builddir}" "${srcdir}" "${setup_flags[@]}"
    else
        # Reconfigure only when Meson inputs moved; otherwise let Ninja no-op.
        reconfigure=0
        for definition in "${srcdir}/meson.build" "${srcdir}/meson.options"; do
            if [[ -f "${definition}" && "${definition}" -nt "${builddir}/build.ninja" ]]; then
                reconfigure=1
                break
            fi
        done
        if [[ "${reconfigure}" -eq 1 ]]; then
            log "meson setup --reconfigure qml6glsink (meson inputs changed)"
            meson setup --reconfigure "${builddir}" "${srcdir}" "${setup_flags[@]}"
            stale_paths=()
            while IFS= read -r line; do
                if [[ -n "${line}" ]]; then
                    stale_paths+=("${line}")
                fi
            done < <(stale_brew_refs "${builddir}/build.ninja")
            if ((${#stale_paths[@]})); then
                log "reconfigure kept stale Homebrew paths; rebuilding the qml6 build dir"
                repair_brew_missing_refs "${stale_paths[@]}"
                rm -rf "${builddir}"
                meson setup "${builddir}" "${srcdir}" "${setup_flags[@]}"
            fi
        fi
    fi

    if ! ninja -C "${builddir}" 2>&1 | tee "${GST_QML6_ROOT}/ninja.log"; then
        # Auto-repair the common environment failure: the graph or link line
        # pins an absolute path that no longer exists. Rebuild once from scratch
        # before surfacing the error.
        while IFS= read -r line; do
            if [[ -n "${line}" ]]; then
                missing_paths+=("${line}")
            fi
        done < <(sed -n "s/^ninja: error: '\([^']*\)'.*/\1/p" "${GST_QML6_ROOT}/ninja.log" | sort -u)
        if ((${#missing_paths[@]})); then
            log "ninja references missing paths; rebuilding the qml6 build dir once"
            repair_brew_missing_refs "${missing_paths[@]}"
            rm -rf "${builddir}"
            meson setup "${builddir}" "${srcdir}" "${setup_flags[@]}"
            ninja -C "${builddir}" || die "ninja failed to build the qml6 plugin (log: ${GST_QML6_ROOT}/ninja.log)"
        else
            die "ninja failed to build the qml6 plugin (log: ${GST_QML6_ROOT}/ninja.log)"
        fi
    fi

    [[ -f "${GST_QML6_PLUGIN}" ]] || die "qml6 plugin was not built at ${GST_QML6_PLUGIN}"
    log "built ${GST_QML6_PLUGIN}"
}

ensure_macos
ensure_xcode
ensure_homebrew
ensure_submodules

if [[ "${SKIP_DEPS:-}" != 1 ]]; then
    ensure_brew_deps
fi

ensure_rust
ensure_qt_env
ensure_pkg_config_path
ensure_ninja_generator
drop_stale_build_caches

# ponytail: check for static Qt and skip gst_qml6 if using static build
if [[ -f "${STATIC_QT_MARKER}" ]]; then
    log "Found static Qt build, using pre-compiled libraries"
    log "$(cat "${STATIC_QT_MARKER}")"
    # ponytail: static Qt already includes qml plugin, skip gst_qml6 build
    GST_QML6_PLUGIN=""
else
    ensure_gst_qml6
fi

log "QMAKE=${QMAKE}"
log "CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}"

HAS_RELEASE=0
for arg in "$@"; do
    if [[ "${arg}" == "--release" ]]; then
        HAS_RELEASE=1
        break
    fi
done

if [[ "${HAS_RELEASE}" == 1 ]]; then
    PROFILE="release"
    log "building release profile"
    cargo build --release "$@"
else
    PROFILE="debug"
    log "building debug profile (pass --release for optimized build)"
    cargo build "$@"
fi

VERSION="$(awk -F'"' '/^version = "/ { print $2; exit }' Cargo.toml)"
if [[ -z "${VERSION}" ]]; then
    die "failed to read package version from Cargo.toml"
fi

case "$(uname -m)" in
    arm64) ARCH="arm64" ;;
    x86_64) ARCH="x86_64" ;;
    *)
        die "unsupported macOS architecture: $(uname -m)"
        ;;
esac

log "staging iDescriptor.app (${PROFILE}, ${ARCH}, ${VERSION})"
# Local builds stage the .app only; IDESCRIPTOR_INCREMENTAL_DEPLOY=0 asks
# deploy.sh for the full DMG path used by release/CI.
IDESCRIPTOR_CARGO_PROFILE="${PROFILE}" \
IDESCRIPTOR_APP_ONLY="${IDESCRIPTOR_INCREMENTAL_DEPLOY:-1}" \
IDESCRIPTOR_GST_QML6_PLUGIN="${GST_QML6_PLUGIN}" \
    bash packaging/macos/dmg/deploy.sh "${ARCH}" "${VERSION}"

log "app ready at ${ROOT}/build/iDescriptor.app"
