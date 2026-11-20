---
name: devstack-restart
description: Restart a DevStack service in one of this repo's Vagrant boxes, on exactly the VMs where that service is enabled. Maps friendly names like "neutron-api", "neutron-openvswitch-agent", "ovn-controller", or "nova-compute" to devstack@ systemd units, restarts the controller before compute nodes, and verifies the unit came back. Use when the user asks to restart, reload, or bounce a service in a DevStack box (e.g. "restart neutron-api", "restart ovn-controller on the compute node").
---

# Restart a DevStack service

Code is edited locally through `local_src` (SSHFS mount of `/opt/stack`), and
DevStack runs from `/opt/stack/<project>` editable installs, so a source change
takes effect after the owning service restarts.

## Quick start

```sh
.agents/skills/devstack-restart/scripts/restart.sh <box-dir> <service> [machine] [--dry-run]
```

Examples:

```sh
# single node
.agents/skills/devstack-restart/scripts/restart.sh devstack/Ubuntu/ovn neutron-api

# multinode: only the machines where the OVS agent is enabled are touched
.agents/skills/devstack-restart/scripts/restart.sh devstack/Ubuntu/multinode_dvr neutron-openvswitch-agent

# everything neutron, API first
.agents/skills/devstack-restart/scripts/restart.sh devstack/Ubuntu/multinode_ovn neutron

# one machine only
.agents/skills/devstack-restart/scripts/restart.sh devstack/Ubuntu/multinode_dvr neutron-api dvr-controller

# show the plan without restarting
.agents/skills/devstack-restart/scripts/restart.sh devstack/Ubuntu/ovn neutron --dry-run
```

## Choosing the box

If the user names a box (`devstack/Ubuntu/ovn`, "the dvr box"), use it. If they
just say "restart neutron-api", infer the active box from the SSHFS mounts:

```sh
for d in devstack/*/*; do
    [[ -f "$d/Vagrantfile" ]] || continue
    if mountpoint -q "$d/local_src" || mountpoint -q "$d/local_src/controller"; then
        echo "$d"
    fi
done
```

- Exactly one result → use that box.
- Several results → ask which box, unless the user's context makes it obvious.
- No result → check `vagrant global-status` / `vagrant status` in the likely box
  directories and ask rather than guessing.

## Service mapping

| User says | systemd unit |
| --- | --- |
| neutron-api, neutron-server, api | `devstack@q-svc.service` |
| neutron-openvswitch-agent, ovs-agent, l2-agent | `devstack@q-agt.service` |
| neutron-linuxbridge-agent | `devstack@q-lb.service` |
| neutron-l3-agent, l3-agent | `devstack@q-l3.service` |
| neutron-dhcp-agent, dhcp-agent | `devstack@q-dhcp.service` |
| neutron-metadata-agent, metadata-agent | `devstack@q-meta.service` |
| neutron-ovn-agent | `devstack@q-ovn-agent.service` |
| ovn-controller | `devstack@ovn-controller.service` |
| ovn-northd | `devstack@ovn-northd.service` |
| nova-api, n-api | `devstack@n-api.service` |
| nova-compute, n-cpu | `devstack@n-cpu.service` |
| neutron | all neutron units, API first |
| `devstack@foo.service` | used as-is |

The script checks every running machine for the unit and restarts only where it
is enabled. That means:

- `neutron-api` (`q-svc`) runs on the controller only — computes are untouched.
- agents (`q-agt`, `ovn-controller`, `q-ovn-agent`, …) run on the controller
  and/or computes depending on the box; all machines that have the unit are
  handled.
- Machines matching `controller` / `allinone` are restarted first, then compute
  nodes, one at a time.

For a service not in the table, run the script with that name anyway: it looks
for a matching `devstack@` unit and uses it only if there is exactly one match.
Otherwise it prints the candidates. Do not restart a service whose unit you have
not identified — list units first:

```sh
vagrant ssh <machine> -c "systemctl list-units 'devstack@*'"
```

## After restarting

The script waits for `systemctl is-active`, and on failure prints
`systemctl status` plus the last 30 journal lines. When the service is a neutron
API or agent, confirm the control plane if the user asks:

```sh
vagrant ssh <machine> -c 'cd /opt/stack/devstack && source openrc admin admin && openstack network agent list'
```

## Rules

- Restart only after the user's change is complete. A half-written module can
  leave `neutron-api` crash-looping.
- Restart the smallest set of services that owns the code. Do not bounce every
  `devstack@` unit or run `unstack.sh` unless explicitly asked.
- The box must be running; the script refuses otherwise. Bring it up with the
  `deploy-devstack` skill instead of starting units by hand.
- If the restart needs a sudo password, the script fails with that message. Ask
  the user rather than putting a password in a command line.
- Never edit files inside the VM directly when the same file is reachable through
  `local_src`; pick one side and report which one you used.
