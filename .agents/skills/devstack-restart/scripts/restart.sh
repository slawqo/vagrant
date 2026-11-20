#!/usr/bin/env bash
# Restart a DevStack service on the Vagrant machine(s) where it actually runs.
#
#   restart.sh <vagrant-dir> <service> [machine] [--dry-run]
#
# <service> is a friendly name (neutron-api, ovn-controller, neutron) or a
# systemd unit (devstack@q-svc.service). The script checks every running VM for
# the unit, so the controller/compute split is discovered, not assumed.

set -uo pipefail

usage() {
    cat >&2 <<'EOF'
usage: restart.sh <vagrant-dir> <service> [machine] [--dry-run]

services:
  neutron-api, neutron-server, api        devstack@q-svc.service
  neutron-openvswitch-agent, ovs-agent    devstack@q-agt.service
  neutron-linuxbridge-agent               devstack@q-lb.service
  neutron-l3-agent, l3-agent              devstack@q-l3.service
  neutron-dhcp-agent, dhcp-agent          devstack@q-dhcp.service
  neutron-metadata-agent, metadata-agent  devstack@q-meta.service
  neutron-ovn-agent                       devstack@q-ovn-agent.service
  ovn-controller                          devstack@ovn-controller.service
  ovn-northd                              devstack@ovn-northd.service
  nova-api, n-api                         devstack@n-api.service
  nova-compute, n-cpu                     devstack@n-cpu.service
  neutron                                 all neutron units, API first
  devstack@foo.service                    used as-is
EOF
}

if [[ $# -lt 2 ]]; then
    usage
    exit 2
fi

dir=$1
svc=$2
shift 2

machine_filter=""
dry_run=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) machine_filter=$arg ;;
    esac
done

if [[ ! -f "$dir/Vagrantfile" ]]; then
    echo "error: no Vagrantfile in $dir" >&2
    exit 2
fi

cd "$dir" || exit 2

units_for() {
    case "${svc,,}" in
        neutron-api|neutron-server|api|q-svc) echo "devstack@q-svc.service" ;;
        neutron-openvswitch-agent|openvswitch-agent|ovs-agent|l2-agent|q-agt) echo "devstack@q-agt.service" ;;
        neutron-linuxbridge-agent|linuxbridge-agent|q-lb) echo "devstack@q-lb.service" ;;
        neutron-l3-agent|l3-agent|q-l3) echo "devstack@q-l3.service" ;;
        neutron-dhcp-agent|dhcp-agent|q-dhcp) echo "devstack@q-dhcp.service" ;;
        neutron-metadata-agent|metadata-agent|q-meta) echo "devstack@q-meta.service" ;;
        neutron-ovn-agent|q-ovn-agent) echo "devstack@q-ovn-agent.service" ;;
        ovn-controller) echo "devstack@ovn-controller.service" ;;
        ovn-northd) echo "devstack@ovn-northd.service" ;;
        nova-api|n-api) echo "devstack@n-api.service" ;;
        nova-compute|n-cpu) echo "devstack@n-cpu.service" ;;
        neutron)
            for u in q-svc q-agt q-ovn-agent ovn-controller q-l3 q-dhcp q-meta q-lb; do
                echo "devstack@$u.service"
            done
            ;;
        devstack@*|*.service) echo "$svc" ;;
        *) return 1 ;;
    esac
}

mapfile -t machines_all < <(
    vagrant status --machine-readable 2>/dev/null |
        awk -F, '$3 == "state" && $2 != "" && $4 == "running" { print $2 }'
)

if (( ${#machines_all[@]} == 0 )); then
    echo "error: no running machines (cd $PWD && vagrant status)" >&2
    exit 2
fi

machines=()
for m in "${machines_all[@]}"; do
    if [[ -n "$machine_filter" && "$m" != "$machine_filter" ]]; then
        continue
    fi
    machines+=("$m")
done

if (( ${#machines[@]} == 0 )); then
    echo "error: machine '$machine_filter' is not running" >&2
    exit 2
fi

# Controller first: it owns the API and must be healthy before agents.
ordered=()
for m in "${machines[@]}"; do
    [[ "$m" =~ controller|allinone ]] && ordered+=("$m")
done
for m in "${machines[@]}"; do
    [[ "$m" =~ controller|allinone ]] || ordered+=("$m")
done

readarray -t units < <(units_for)

if (( ${#units[@]} == 0 )); then
    echo "error: unknown service '$svc'; looking for a matching devstack unit" >&2
    matches=$(vagrant ssh "${ordered[0]}" -c \
        "systemctl list-unit-files --no-legend 'devstack@*' | awk '{print \$1}' | grep -i -- '$svc'" 2>/dev/null)
    if [[ $(wc -l <<<"$matches") -eq 1 && -n "$matches" ]]; then
        units=("$matches")
        echo "using $matches"
    else
        echo "candidates:" >&2
        echo "${matches:-  (none)}" >&2
        echo "run 'vagrant ssh ${ordered[0]} -c \"systemctl list-units 'devstack@*'\"' to see them" >&2
        exit 2
    fi
fi

unit_present() {
    local m=$1 u=$2
    vagrant ssh "$m" -c "systemctl cat '$u' >/dev/null 2>&1 && systemctl is-enabled '$u' >/dev/null 2>&1"
}

rc=0
touched=0

for unit in "${units[@]}"; do
    found=0
    for machine in "${ordered[@]}"; do
        if ! unit_present "$machine" "$unit"; then
            continue
        fi
        found=1
        touched=1

        if (( dry_run )); then
            echo "[dry-run] $machine: systemctl restart $unit"
            continue
        fi

        echo "$machine: restarting $unit"
        if ! vagrant ssh "$machine" -c "sudo -n systemctl restart '$unit'"; then
            echo "error: restart failed on $machine (sudo may need a password)" >&2
            rc=1
            continue
        fi

        active=0
        for _ in $(seq 1 30); do
            if vagrant ssh "$machine" -c "systemctl is-active --quiet '$unit'" >/dev/null 2>&1; then
                active=1
                break
            fi
            sleep 2
        done

        if (( active )); then
            echo "$machine: $unit is active"
        else
            echo "error: $unit did not become active on $machine" >&2
            vagrant ssh "$machine" -c "systemctl status '$unit' --no-pager -l | tail -n 25" >&2
            vagrant ssh "$machine" -c "sudo -n journalctl -u '$unit' -n 30 --no-pager" >&2
            rc=1
        fi
    done

    if (( !found )); then
        echo "note: $unit is not enabled on: ${ordered[*]}"
    fi
done

if (( !touched )); then
    echo "error: no running machine has any of: ${units[*]}" >&2
    echo "check with: vagrant ssh ${ordered[0]} -c \"systemctl list-units 'devstack@*'\"" >&2
    exit 2
fi

exit $rc
