#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$ROOT_DIR/repos"
BIN_DIR="$ROOT_DIR/bin"

THREAD_CORE="${RTSYN_THREAD_CORE:-preempt_rt}"
BUILD_MODE="${RTSYN_BUILD_MODE:-release}"

if ((EUID == 0)); then
    printf 'error: do not run this setup script with sudo or as root.\n' >&2
    printf 'run it as your normal user instead:\n' >&2
    printf '  bash %q\n' "$ROOT_DIR/setup.bash" >&2
    printf 'setup will request sudo only to stage and set capabilities on the final RTSyn executable.\n' >&2
    exit 1
fi

mkdir -p "$REPOS_DIR" "$BIN_DIR"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'error: required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

find_admin_command() {
    local name="$1"
    local candidate

    candidate="$(command -v "$name" 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
        printf '%s' "$candidate"
        return
    fi
    for candidate in "/usr/sbin/$name" "/sbin/$name"; do
        if [[ -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return
        fi
    done
    return 1
}

clone_repo() {
    local name="$1"
    local url="$2"
    local destination="$REPOS_DIR/$name"

    if [[ -d "$destination/.git" ]]; then
        printf 'Using existing repository: %s\n' "$destination"
        return
    fi
    if [[ -e "$destination" ]]; then
        printf 'error: %s exists but is not a Git repository\n' "$destination" >&2
        exit 1
    fi

    git clone "$url" "$destination"
}

ensure_rtsyn_xmake_repo() {
    local repositories
    repositories="$(env -u RTSYN_WORKSPACE xmake repo --list --global 2>/dev/null || true)"
    if printf '%s\n' "$repositories" | \
        awk '$1 == "rtsyn-xmake-repo" { found = 1 } END { exit(found ? 0 : 1) }'; then
        printf 'Using registered Xmake repository: rtsyn-xmake-repo\n'
        return
    fi

    printf 'RTSyn Xmake repository is not registered; installing it locally...\n'
    clone_repo rtsyn-xmake-repo https://github.com/rtsyn-developers/rtsyn-xmake-repo.git
    env -u RTSYN_WORKSPACE xmake repo --add --global \
        rtsyn-xmake-repo "$REPOS_DIR/rtsyn-xmake-repo"
}

copy_release_artifact() {
    local repository="$1"
    local filename="$2"
    local source

    # RTSyn sets a project-local target directory, while the standalone module
    # projects currently let Xmake resolve their target directory relative to
    # the invoking validation repository. Support both layouts explicitly.
    source="$(find "$repository/build" "$ROOT_DIR/build" \
        -type f -path "*/$BUILD_MODE/$filename" -print -quit 2>/dev/null || true)"
    if [[ -z "$source" ]]; then
        printf 'error: build artifact not found: %s (%s)\n' "$filename" "$repository" >&2
        exit 1
    fi
    # Remove an earlier staging symlink before copying a newly built artifact.
    rm -f "$BIN_DIR/$filename"
    cp "$source" "$BIN_DIR/$filename"
}

require_command git
require_command xmake
require_command cargo
if [[ "$THREAD_CORE" == "preempt_rt" ]]; then
    SETCAP_BIN="$(find_admin_command setcap)" || {
        printf 'error: setcap not found; on Debian install it with:\n' >&2
        printf '  sudo apt install libcap2-bin\n' >&2
        exit 1
    }
    GETCAP_BIN="$(find_admin_command getcap)" || {
        printf 'error: getcap not found; on Debian install it with:\n' >&2
        printf '  sudo apt install libcap2-bin\n' >&2
        exit 1
    }
fi

clone_repo rtsyn https://github.com/rtsyn-developers/rtsyn.git
clone_repo rtsyn-module-device-comedi https://github.com/rtsyn-developers/rtsyn-module-device-comedi.git
clone_repo rthybrid-hindmarsh-rose-1984-neuron-v2 \
    https://github.com/rtsyn-developers/rthybrid-hindmarsh-rose-1984-neuron-v2.git
clone_repo rthybrid-electrical-synapse \
    https://github.com/rtsyn-developers/rthybrid-electrical-synapse.git
clone_repo rthybrid-burst-analysis \
    https://github.com/rtsyn-developers/rthybrid-burst-analysis.git
clone_repo rthybrid-amplitude-scale-offset \
    https://github.com/rtsyn-developers/rthybrid-amplitude-scale-offset.git

ensure_rtsyn_xmake_repo

printf 'Building RTSyn (%s, thread core %s)...\n' "$BUILD_MODE" "$THREAD_CORE"
env -u RTSYN_WORKSPACE xmake f -P "$REPOS_DIR/rtsyn" -c -y \
    --mode="$BUILD_MODE" --thread_core="$THREAD_CORE"
# Refresh the standalone package graph so the launcher and embedded daemon use
# the same API/package revisions instead of stale globally cached versions.
env -u RTSYN_WORKSPACE xmake require -P "$REPOS_DIR/rtsyn" -f -y
env -u RTSYN_WORKSPACE xmake build -P "$REPOS_DIR/rtsyn" -y rtsyn

printf 'Building Comedi device module and diagnostics...\n'
env -u RTSYN_WORKSPACE xmake f -P "$REPOS_DIR/rtsyn-module-device-comedi" \
    -c -y --mode="$BUILD_MODE" --tests=n
env -u RTSYN_WORKSPACE xmake build -P "$REPOS_DIR/rtsyn-module-device-comedi" \
    -y rtsyn-comedi comedi-loopback comedi-digital-loopback

printf 'Building Hindmarsh-Rose plugin...\n'
env -u RTSYN_WORKSPACE xmake f \
    -P "$REPOS_DIR/rthybrid-hindmarsh-rose-1984-neuron-v2" \
    -c -y --mode="$BUILD_MODE" --tests=n
env -u RTSYN_WORKSPACE xmake build \
    -P "$REPOS_DIR/rthybrid-hindmarsh-rose-1984-neuron-v2" \
    -y rthybrid-hindmarsh-rose-1984-neuron-v2

for plugin in rthybrid-electrical-synapse rthybrid-burst-analysis rthybrid-amplitude-scale-offset; do
    printf 'Building %s plugin...\n' "$plugin"
    env -u RTSYN_WORKSPACE xmake f -P "$REPOS_DIR/$plugin" -c -y \
        --mode="$BUILD_MODE" --tests=n
    env -u RTSYN_WORKSPACE xmake build -P "$REPOS_DIR/$plugin" -y "$plugin"
done

copy_release_artifact "$REPOS_DIR/rtsyn" rtsyn
copy_release_artifact "$REPOS_DIR/rtsyn-module-device-comedi" librtsyn-comedi.so
copy_release_artifact "$REPOS_DIR/rtsyn-module-device-comedi" comedi-loopback
copy_release_artifact "$REPOS_DIR/rtsyn-module-device-comedi" comedi-digital-loopback
copy_release_artifact "$REPOS_DIR/rthybrid-hindmarsh-rose-1984-neuron-v2" \
    librthybrid-hindmarsh-rose-1984-neuron-v2.so
copy_release_artifact "$REPOS_DIR/rthybrid-electrical-synapse" \
    librthybrid-electrical-synapse.so
copy_release_artifact "$REPOS_DIR/rthybrid-burst-analysis" \
    librthybrid-burst-analysis.so
copy_release_artifact "$REPOS_DIR/rthybrid-amplitude-scale-offset" \
    librthybrid-amplitude-scale-offset.so

chmod +x "$BIN_DIR/rtsyn" "$BIN_DIR/comedi-loopback" "$BIN_DIR/comedi-digital-loopback"

if [[ "$THREAD_CORE" == "preempt_rt" ]]; then
    require_command sudo
    require_command findmnt

    # Always stage the PREEMPT_RT executable on a system filesystem. Mount
    # namespaces and bind mounts can make nosuid detection differ between
    # setup and execution, while silently making otherwise visible file
    # capabilities ineffective.
    capability_dir="${RTSYN_CAPABILITY_DIR:-/usr/local/libexec/rtsyn-validation-tests}"
    capability_target="$capability_dir/rtsyn"
    sudo install -D -m 0755 "$BIN_DIR/rtsyn" "$capability_target"

    capability_mount_options="$(findmnt -n -o OPTIONS -T "$capability_target" 2>/dev/null || true)"
    if [[ ",$capability_mount_options," == *,nosuid,* ]]; then
        printf 'error: capability staging path %s is on a nosuid filesystem\n' \
            "$capability_target" >&2
        printf 'set RTSYN_CAPABILITY_DIR to a path on a filesystem without nosuid\n' >&2
        exit 1
    fi

    rm -f "$BIN_DIR/rtsyn"
    ln -s "$capability_target" "$BIN_DIR/rtsyn"
    printf 'Staged PREEMPT_RT executable: %s\n' "$capability_target"

    printf 'Granting PREEMPT_RT capabilities to %s...\n' "$capability_target"
    sudo "$SETCAP_BIN" cap_sys_nice,cap_ipc_lock=eip "$capability_target"

    capabilities="$("$GETCAP_BIN" "$capability_target")"
    if [[ "$capabilities" != *cap_sys_nice* || "$capabilities" != *cap_ipc_lock* ]]; then
        printf 'error: required capabilities were not applied: %s\n' "$capabilities" >&2
        exit 1
    fi
    printf 'Capabilities verified: %s\n' "$capabilities"
fi

printf '\nInstalled validation artifacts in %s:\n' "$BIN_DIR"
find "$BIN_DIR" -maxdepth 1 \( -type f -o -type l \) -printf '  %f\n' | sort

printf '\nRun the NI PCI-6024E validation with:\n'
printf '  %q 30\n' "$ROOT_DIR/tests/loopback-performance/ni-pci-6024e.bash"
