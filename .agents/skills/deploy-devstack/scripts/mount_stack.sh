#!/usr/bin/env bash
# Mount /opt/stack from a running Vagrant box into <box-dir>/local_src.
#
#   mount_stack.sh <vagrant-dir> [mount|unmount|status]
#
# Single-machine boxes mount at <box-dir>/local_src.
# Multi-machine boxes mount each VM at <box-dir>/local_src/<machine>.
#
# The mount is SSHFS: edits made locally are written straight to the VM.
# Unmount (or use `vagrant halt`) before stopping a box to avoid a stale mount.

set -uo pipefail

usage() {
    echo "usage: $0 <vagrant-dir> [mount|unmount|status]" >&2
}

dir=${1:-}
action=${2:-mount}

if [[ -z "$dir" || ! -f "$dir/Vagrantfile" ]]; then
    usage
    exit 2
fi

cd "$dir" || exit 2

case "$action" in
    mount|unmount|status) ;;
    *)
        usage
        exit 2
        ;;
esac

mapfile -t machines < <(
    vagrant status --machine-readable 2>/dev/null |
        awk -F, '$3 == "state" && $2 != "" { print $2 }'
)

if (( ${#machines[@]} == 0 )); then
    echo "error: could not determine machine names (cd $PWD && vagrant status)" >&2
    exit 2
fi

state_of() {
    vagrant status --machine-readable "$1" 2>/dev/null |
        awk -F, -v m="$1" '$2 == m && $3 == "state" { print $4; exit }'
}

mountpoint_for() {
    if (( ${#machines[@]} == 1 )); then
        echo "$PWD/local_src"
    else
        echo "$PWD/local_src/$1"
    fi
}

case "$action" in
    status)
        for machine in "${machines[@]}"; do
            mp=$(mountpoint_for "$machine")
            if mountpoint -q "$mp"; then
                if ls "$mp" >/dev/null 2>&1; then
                    echo "$machine: mounted   $mp"
                else
                    echo "$machine: stale     $mp"
                fi
            else
                echo "$machine: unmounted $mp"
            fi
        done
        ;;

    unmount)
        rc=0
        for machine in "${machines[@]}"; do
            mp=$(mountpoint_for "$machine")
            if ! mountpoint -q "$mp"; then
                echo "$machine: not mounted ($mp)"
                continue
            fi
            if ! fusermount3 -u "$mp" 2>/dev/null; then
                fusermount3 -uz "$mp" || { echo "error: cannot unmount $mp" >&2; rc=1; continue; }
            fi
            echo "$machine: unmounted $mp"
        done
        exit $rc
        ;;

    mount)
        rc=0
        for machine in "${machines[@]}"; do
            mp=$(mountpoint_for "$machine")

            if mountpoint -q "$mp"; then
                if ls "$mp" >/dev/null 2>&1; then
                    echo "$machine: already mounted at $mp"
                    continue
                fi
                echo "$machine: stale mount at $mp; remounting"
                fusermount3 -uz "$mp" || { echo "error: cannot clear stale mount $mp" >&2; rc=1; continue; }
            fi

            state=$(state_of "$machine")
            if [[ "$state" != "running" ]]; then
                echo "error: $machine is '$state', not running; start it first" >&2
                rc=1
                continue
            fi

            mkdir -p "$mp"
            if [[ -n "$(ls -A "$mp" 2>/dev/null)" ]]; then
                echo "error: $mp is not empty; refusing to hide local files behind the mount" >&2
                rc=1
                continue
            fi

            if ! vagrant ssh "$machine" -c 'test -r /opt/stack' >/dev/null 2>&1; then
                echo "error: /opt/stack does not exist or is not readable on $machine" >&2
                rc=1
                continue
            fi
            if ! vagrant ssh "$machine" -c 'test -w /opt/stack' >/dev/null 2>&1; then
                echo "warning: /opt/stack is not writable by the SSH user on $machine; edits through $mp will fail"
            fi

            cfg=$(mktemp) || { rc=1; continue; }
            if ! vagrant ssh-config "$machine" >"$cfg" 2>/dev/null; then
                echo "error: cannot read SSH settings for $machine" >&2
                rm -f "$cfg"
                rc=1
                continue
            fi

            host=$(awk '/^[[:space:]]*Host / { print $2; exit }' "$cfg")
            if sshfs -F "$cfg" \
                -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user \
                "$host:/opt/stack" "$mp"; then
                echo "$machine: mounted /opt/stack at $mp"
            else
                echo "error: sshfs failed for $machine" >&2
                rc=1
            fi
            rm -f "$cfg"
        done
        exit $rc
        ;;
esac
