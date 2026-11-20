#!/usr/bin/env bash
# Deploy DevStack inside an already-running Vagrant box.
#
#   deploy.sh <vagrant-dir> [machine]
#
# <vagrant-dir> is the directory containing the Vagrantfile.
# [machine]    is required for multi-machine boxes (e.g. controller, compute-1).
#
# Exit codes: 0 deployed or already deployed, 1 stack.sh failed, 2 bad state/input.

set -uo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <vagrant-dir> [machine]" >&2
    exit 2
fi

dir=$1
machine=${2:-}

if [[ ! -f "$dir/Vagrantfile" ]]; then
    echo "error: no Vagrantfile in $dir" >&2
    exit 2
fi

cd "$dir" || exit 2

ssh_cmd=(vagrant ssh)
if [[ -n "$machine" ]]; then
    ssh_cmd+=("$machine")
fi

run() {
    "${ssh_cmd[@]}" -c "$1"
}

label=${machine:-"default machine"}
log=/opt/stack/logs/stack.sh.log

if ! run 'true' >/dev/null 2>&1; then
    echo "error: cannot SSH into $label; is the box running? (cd $dir && vagrant status)" >&2
    exit 2
fi

if ! run 'test -x /opt/stack/devstack/stack.sh'; then
    echo "error: /opt/stack/devstack/stack.sh is missing on $label." >&2
    echo "       The box exists but was not provisioned. Run 'vagrant provision' first." >&2
    exit 2
fi

units=$(run 'systemctl list-units --type=service --state=running "devstack@*" --no-legend 2>/dev/null | wc -l' | tr -d '[:space:]')
if [[ ${units:-0} -gt 0 ]] && run 'test -f /opt/stack/devstack/openrc'; then
    echo "already deployed on $label: $units devstack@ units running"
    exit 0
fi

echo "launching stack.sh on $label (log: $log)"

run 'cd /opt/stack/devstack && rm -f /tmp/stack.sh.exit && setsid nohup bash -c "./stack.sh >/tmp/stack.sh.out 2>&1; echo \$? >/tmp/stack.sh.exit" >/dev/null 2>&1 </dev/null & echo launched'

timeout=${STACK_TIMEOUT:-5400}
deadline=$((SECONDS + timeout))
next_progress=$((SECONDS + 300))

while ((SECONDS < deadline)); do
    sleep 30
    if run 'test -f /tmp/stack.sh.exit' >/dev/null 2>&1; then
        code=$(run 'cat /tmp/stack.sh.exit' | tr -dc '0-9')
        if [[ "$code" == "0" ]]; then
            echo "stack.sh finished successfully on $label"
            run 'systemctl list-units --type=service --state=running "devstack@*" --no-legend | wc -l'
            exit 0
        fi
        echo "error: stack.sh failed on $label (exit $code)" >&2
        echo "--- last 40 lines of $log ---" >&2
        run "tail -n 40 $log" >&2
        echo "--- last 20 lines of /tmp/stack.sh.out ---" >&2
        run 'tail -n 20 /tmp/stack.sh.out' >&2
        exit 1
    fi

    if ((SECONDS >= next_progress)); then
        echo "[$(( (SECONDS - (deadline - timeout)) / 60 )) min] $(run 'tail -n 1 /opt/stack/logs/stack.sh.log' 2>/dev/null)"
        next_progress=$((SECONDS + 300))
    fi
done

echo "error: stack.sh did not finish within ${timeout}s on $label" >&2
echo "       It may still be running; check with: vagrant ssh ${machine:-} -c 'pgrep -af stack.sh'" >&2
exit 1
