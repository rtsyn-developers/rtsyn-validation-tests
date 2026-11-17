#!/usr/bin/env bash
# Build/stage the sibling development workspace without cloning RTSyn sources.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RTSYN_WORKSPACE="${RTSYN_WORKSPACE:-$(dirname "$ROOT_DIR")}"
RTSYN_WORKSPACE="$(cd "$RTSYN_WORKSPACE" && pwd)"
MODE="${RTSYN_BUILD_MODE:-release}"
if (($#)); then
    echo 'usage: setup-local.bash' >&2
    exit 1
fi
BIN_DIR="$ROOT_DIR/bin"
CAPABILITY_DIR="${RTSYN_CAPABILITY_DIR:-/usr/local/libexec/rtsyn-validation-tests}"
LAUNCHER_SOURCE="$BIN_DIR/rtsyn.local-ready"
LAUNCHER_TARGET="$CAPABILITY_DIR/rtsyn"
mkdir -p "$BIN_DIR"
for project in rtsyn rtsyn-ui rtsyn-abi rtsyn-module-device-comedi rtsyn-xmake-repo; do
    [[ -d "$RTSYN_WORKSPACE/$project" ]] || { echo "error: missing local $project" >&2; exit 1; }
done

# The aggregate workspace build compiles native siblings and patches Cargo to
# the local rtsyn-ui checkout. No git push, pull or clone occurs here.
xmake f -P "$RTSYN_WORKSPACE/rtsyn" -y --mode="$MODE" --thread_core=preempt_rt
xmake build -P "$RTSYN_WORKSPACE/rtsyn" -y rtsyn

stage_file() {
    local source="$1" target="$2"
    [[ -f "$source" ]] || { echo "error: missing build artifact $source" >&2; exit 1; }
    cp "$source" "$target.new"
    mv -f "$target.new" "$target"
    cmp "$source" "$target"
}

stage_launcher() {
    [[ -f "$LAUNCHER_SOURCE" ]] || {
        echo "error: missing built launcher $LAUNCHER_SOURCE" >&2
        exit 1
    }
    command -v findmnt >/dev/null || { echo 'error: findmnt is required' >&2; exit 1; }
    find_admin_tool() {
        local tool="$1" candidate
        candidate="$(command -v "$tool" 2>/dev/null || true)"
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
        for candidate in "/usr/sbin/$tool" "/sbin/$tool"; do
            if [[ -x "$candidate" ]]; then
                printf '%s' "$candidate"
                return 0
            fi
        done
        return 1
    }
    local setcap_bin getcap_bin mount_options capabilities
    setcap_bin="$(find_admin_tool setcap)" || true
    getcap_bin="$(find_admin_tool getcap)" || true
    if [[ -z "$setcap_bin" || -z "$getcap_bin" ]]; then
        echo 'error: setcap and getcap are required to stage the realtime launcher' >&2
        exit 1
    fi
    mount_options="$(findmnt -n -o OPTIONS -T "$CAPABILITY_DIR")"
    if [[ ",$mount_options," == *,nosuid,* ]]; then
        echo "error: $CAPABILITY_DIR is on a nosuid filesystem; choose another RTSYN_CAPABILITY_DIR" >&2
        exit 1
    fi

    local sudo=()
    if ((EUID != 0)); then sudo=(sudo); fi
    local staged="$LAUNCHER_TARGET.local-new"
    "${sudo[@]}" install -D -m 0755 "$LAUNCHER_SOURCE" "$staged"
    "${sudo[@]}" "$setcap_bin" cap_sys_nice,cap_ipc_lock=eip "$staged"
    # Replace by rename so a running daemon can finish on its old executable.
    "${sudo[@]}" mv -f -- "$staged" "$LAUNCHER_TARGET"

    ln -s "$LAUNCHER_TARGET" "$BIN_DIR/rtsyn.link-new"
    mv -Tf "$BIN_DIR/rtsyn.link-new" "$BIN_DIR/rtsyn"
    cmp "$LAUNCHER_SOURCE" "$LAUNCHER_TARGET"
    capabilities="$("$getcap_bin" "$LAUNCHER_TARGET")"
    [[ "$capabilities" == *cap_sys_nice* && "$capabilities" == *cap_ipc_lock* ]] || {
        echo 'error: installed launcher is missing realtime capabilities' >&2
        exit 1
    }
    printf 'Staged local launcher: %s\n%s\n' "$LAUNCHER_TARGET" "$capabilities"
}

build_module() {
    local project="$1" target="$2" filename="$3"
    # Run inside the project so Xmake's relative build directory is unambiguous.
    (
        cd "$project"
        xmake f -y --mode="$MODE" --tests=n \
            --includedirs="$RTSYN_WORKSPACE/rtsyn-abi/include:$RTSYN_WORKSPACE/rtsyn-module-loader/include"
        xmake build -y "$target"
    )
    stage_file "$project/build/linux/$(uname -m)/$MODE/$filename" "$BIN_DIR/$filename"
}
build_module "$RTSYN_WORKSPACE/rtsyn-module-device-comedi" rtsyn-comedi librtsyn-comedi.so
for tool in comedi-loopback comedi-digital-loopback; do
    (cd "$RTSYN_WORKSPACE/rtsyn-module-device-comedi" && xmake build -y "$tool")
    stage_file "$RTSYN_WORKSPACE/rtsyn-module-device-comedi/build/linux/$(uname -m)/$MODE/$tool" "$BIN_DIR/$tool"
done
for plugin in hindmarsh-rose-1984-neuron-v2 electrical-synapse burst-analysis amplitude-scale-offset; do
    build_module "$RTSYN_WORKSPACE/rthybrid-rtsyn-modules/rthybrid-$plugin" \
        "rthybrid-$plugin" "librthybrid-$plugin.so"
done
stage_file "$RTSYN_WORKSPACE/rtsyn/build/linux/$(uname -m)/$MODE/rtsyn" "$BIN_DIR/rtsyn.local-ready"
(
    cd "$BIN_DIR"
    sha256sum rtsyn.local-ready librtsyn-comedi.so librthybrid-*.so comedi-loopback comedi-digital-loopback
) > "$BIN_DIR/local-build-sha256.txt"
printf 'Local build prepared in %s\n' "$BIN_DIR"
stage_launcher
