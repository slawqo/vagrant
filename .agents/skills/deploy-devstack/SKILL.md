---
name: deploy-devstack
description: Deploy or start OpenStack lab boxes in this Vagrant repo. Picks the right Vagrantfile from the request (e.g. "ml2/ovn single node devstack"), brings halted VMs up without re-provisioning, checks whether DevStack is already running, and runs stack.sh when it is not. Afterwards mounts the VM's /opt/stack into local_src with SSHFS (one subfolder per node on multinode) so project code can be edited locally. Use when the user asks to deploy, start, bring up, mount, or check a DevStack, fullstack, TripleO, Packstack, or generic Vagrant box from this repo.
---

# Deploy a Vagrant lab box

## Step 1: pick the box directory

Use the request to select exactly one directory. Default to Ubuntu when no OS is
given, and say so in the report.

### DevStack boxes

| Request sounds like | Directory | Machines | Networking |
| --- | --- | --- | --- |
| single node / all-in-one / ml2-ovn / ovn | `devstack/Ubuntu/ovn` | `devstack-ubuntu-ovn` | OVN, allinone |
| single node / ovs / ml2-ovs / openvswitch | `devstack/Ubuntu/ovs` | `devstack-ubuntu-ovs` | OVS, allinone |
| single node / linuxbridge | `devstack/Ubuntu/linuxbridge` | `devstack-ubuntu-linuxbridge` | Linuxbridge, allinone |
| multinode + ovn | `devstack/Ubuntu/multinode_ovn` | `controller`, `compute` | OVN, multinode |
| multinode + dvr / dvr_snat | `devstack/Ubuntu/multinode_dvr` | `dvr-controller`, `dvr-compute-1`, `dvr-compute-2` | OVS + DVR |
| multinode + legacy l3 | `devstack/Ubuntu/multinode_legacy` | `controller`, `compute-1`, `compute-2`, `compute-3` | OVS + legacy |
| centos + ovn | `devstack/Centos/ovn` | `devstack-centos-ovn` | OVN, allinone |
| centos + ovs | `devstack/Centos/ovs` | `devstack-centos-ovs` | OVS, allinone |
| centos + linuxbridge | `devstack/Centos/linuxbridge` | `devstack-centos-linuxbridge` | Linuxbridge, allinone |
| centos + multinode + ovn | `devstack/Centos/multinode_ovn` | `controller`, `compute` | OVN, multinode |
| fedora + devstack | `devstack/Fedora/ovs` | `devstack-fedora-ovs` | OVS, allinone |

"ml2" alone does not identify a box: ask whether the user means OVN, OVS, or
linuxbridge. "multinode" without a mode: ask. Never guess between two rows.

### Everything else (no DevStack deploy)

| Request | Directory | Machines | After `vagrant up` |
| --- | --- | --- | --- |
| fullstack (Ubuntu) | `fullstack/Ubuntu` | `fullstack-ubuntu` | Provisioned by Ansible; do NOT run `stack.sh` |
| fullstack old / stable | `fullstack/Ubuntu_old` | `fullstack-ubuntu-old` | Same, no `stack.sh` |
| fullstack centos | `fullstack/Centos` | `fullstack-centos` | Same, no `stack.sh` |
| fedora vm / packaging vm | `fedora-vm` | `fedora-vm` | Dev toolbox only |
| generic centos vm | `generic-centos-vm` | `generic-centos-vm` | Dev toolbox only |
| tripleo | `tripleo` | `tripleo-centos` | Dev toolbox only |
| packstack | `packstack/Centos` | `packstack-centos` | Legacy; no `stack.sh` |

`fullstack` *does* contain OpenStack, but it is installed during provisioning, not
by DevStack. Only verify it if asked; never deploy it.

## Step 2: check the current state

Run from the chosen directory:

```sh
vagrant status
```

| State | Action |
| --- | --- |
| `running` | Skip `vagrant up`; go to step 3 |
| `shutoff` / `poweroff` / `saved` | `vagrant up` (starts only, does not re-provision) |
| `paused` | `vagrant resume` |
| `not created` | `vagrant up` runs provisioning; see vault note below |

State and machine names for multi-VM boxes:

```sh
vagrant status --machine-readable | grep ',state,'
```

### Vault password on first boot

Provisioning needs the Ansible vault password. Check the Vagrantfile:

```sh
grep -n 'ask_vault_pass\|vault_password_file' Vagrantfile
```

- `ask_vault_pass = true` prompts interactively. An agent cannot answer it: ask
  the user to run `vagrant up` in that directory themselves, then continue with
  step 3. Do not edit the Vagrantfile or pass the password through the shell.
- `vault_password_file = ...` (Ubuntu `multinode_*` use `/tmp/vault_pass`): if
  the file is missing, ask the user to provide it, then retry.
- A box that is only halted never re-provisions, so no password is needed.

`vagrant up` can take 10–40 minutes. Run it in the background and poll
`vagrant status` rather than blocking.

## Step 3: decide whether DevStack must be deployed

Only for the DevStack boxes above. For every other box, report that it is up and
stop.

Check on the target machine (add the machine name for multinode, e.g.
`vagrant ssh controller -c '...'`):

```sh
vagrant ssh -c 'test -x /opt/stack/devstack/stack.sh && echo cloned'
vagrant ssh -c 'systemctl list-units --type=service --state=running "devstack@*" --no-legend | wc -l'
vagrant ssh -c 'test -f /opt/stack/devstack/openrc && echo openrc'
```

- `stack.sh` missing → the box is not provisioned. Run `vagrant provision`
  (vault rules apply) before deploying. Do not try to clone DevStack by hand.
- At least one `devstack@` unit running and `openrc` present → likely deployed.
  Confirm with the API check below, then go to step 5 to mount `local_src`.
- No units and no `openrc` → deploy (step 4).
- Some units but a failing API check → the previous run was partial. Report the
  state and ask whether to re-run `stack.sh`; do not destroy anything.

API check:

```sh
vagrant ssh -c 'cd /opt/stack/devstack && source openrc admin admin >/dev/null 2>&1 && openstack service list'
```

Use the machine name for multinode. If `openstack` is not on `PATH` after
sourcing `openrc`, fall back to the `devstack@` unit count and say so.

## Step 4: deploy with stack.sh

Run the helper from the repo root. It launches `stack.sh` detached, waits for it,
and prints the log tail on failure:

```sh
.agents/skills/deploy-devstack/scripts/deploy.sh <directory> [machine]
```

Run it in the background (it can take 20–40 minutes) and check on it
periodically. It is idempotent: if DevStack is already up it exits immediately.

**Multinode order matters.** Deploy the controller first, wait for success, then
each compute node one at a time:

```sh
.agents/skills/deploy-devstack/scripts/deploy.sh devstack/Ubuntu/multinode_dvr dvr-controller
.agents/skills/deploy-devstack/scripts/deploy.sh devstack/Ubuntu/multinode_dvr dvr-compute-1
.agents/skills/deploy-devstack/scripts/deploy.sh devstack/Ubuntu/multinode_dvr dvr-compute-2
```

Do not start compute nodes in parallel and do not start them before the
controller finished.

## Step 5: expose /opt/stack as local_src

Every DevStack box, once up and deployed, gets `/opt/stack` from the VM mounted
locally with SSHFS. Do this even when the box was already deployed — the mount
does not survive a reboot or a `vagrant halt`.

```sh
.agents/skills/deploy-devstack/scripts/mount_stack.sh <directory>
```

The script is idempotent and lays the mount out by topology:

| Box | Mount point |
| --- | --- |
| single node | `<directory>/local_src` |
| multinode | `<directory>/local_src/controller`, `<directory>/local_src/compute`, … (one directory per machine) |

`local_src` is git-ignored. Edits made through it are written straight to the
VM, so no sync step is needed. The usual target is
`local_src/neutron` (single node) or `local_src/controller/neutron` /
`local_src/compute/neutron` (multinode).

Check the state, and unmount before stopping any box:

```sh
.agents/skills/deploy-devstack/scripts/mount_stack.sh <directory> status
.agents/skills/deploy-devstack/scripts/mount_stack.sh <directory> unmount
```

If the mount point is not empty, the script refuses to mount rather than hide
local files. If SSHFS is not installed, report it; do not install packages
without asking.

After editing a project through the mount, restart the affected services with
the `devstack-restart` skill (`restart.sh <dir> <service>`), which only touches
the machines where that unit is enabled.

## Step 6: verify and report

On the controller (or the single node):

```sh
vagrant ssh -c 'cd /opt/stack/devstack && source openrc admin admin && openstack service list'
vagrant ssh -c 'cd /opt/stack/devstack && source openrc admin admin && openstack compute service list'
```

Report in this shape:

```
Box:        devstack/Ubuntu/ovn (devstack-ubuntu-ovn, OVN, allinone)
State:      was shutoff -> vagrant up
OpenStack:  not deployed -> stack.sh
Result:     24 services enabled, 1 compute node up
Logs:       /opt/stack/logs/stack.sh.log
Mount:      devstack/Ubuntu/ovn/local_src -> /opt/stack
```

For multinode, list each machine's status separately. If something failed, give
the failing machine, the exit code, and the last error lines from
`/opt/stack/logs/stack.sh.log`.

## Guardrails

- Never run `vagrant destroy`, `vagrant halt`, `unstack.sh`, or `clean.sh`
  unless the user explicitly asks. `destroy` deletes the VM and its disks. If
  asked to halt or destroy a box, unmount `local_src` first.
- Never read or edit files under `local_src` unless `mountpoint -q` confirms the
  path is mounted; otherwise the path is just an empty directory or a stale mount.
- Do not mount over a non-empty `local_src`; never delete local files to make a
  mount succeed.
- Do not edit `Vagrantfile`, `local.conf`, or the Ansible roles to work around a
  problem; report the problem instead.
- Do not print or copy vault-encrypted values or anything under `files/gpg`.
- Bring up only the box the user asked for. Starting several 6–16 GB VMs at
  once can exhaust the host.
- If the request does not map cleanly to one row above, ask instead of guessing.
