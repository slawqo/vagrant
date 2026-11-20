# AGENTS.md

## What this repo is

A personal lab of Vagrant boxes used for OpenStack development and testing. Each
subdirectory is a self-contained scenario: a `Vagrantfile` that boots one or more
VMs (libvirt preferred, VirtualBox definitions also present) and then runs Ansible
to provision them.

This is **not** an application codebase. It is infrastructure-as-config that is
edited occasionally — usually to bump a box image, a release branch, or an IP.
Do not look for tests, a build system, or packaged code here. Mirrored publicly
at `github.com/slawqo/vagrant` (`origin`).

The actual provisioning logic lives in a separate Ansible roles repo
(`github.com/slawqo/ansible`), resolved through `ansible.cfg`:

```
roles_path = ~/ansible/roles:~/dev/ansible/roles:~/src/github/slawqo/ansible/roles
```

If a role is missing locally, provisioning fails — fix the roles checkout, not
the `Vagrantfile`.

## Layout

| Path | Purpose |
| --- | --- |
| `devstack/` | DevStack deployments: OS (`Ubuntu`, `Centos`, `Fedora`) × L2/L3 mode (`ovs`, `ovn`, `linuxbridge`, `multinode_*`) |
| `fullstack/` | Full OpenStack from packages on one node (`Ubuntu`, `Ubuntu_old`, `Centos`) |
| `packstack/` | Packstack-based single-node install (legacy CentOS 7) |
| `tripleo/` | TripleO undercloud playground |
| `generic-centos-vm/`, `fedora-vm/` | Plain development VMs (tools, packaging, eBPF/Neutron work) |
| `openstack_provisioning/` | Shared playbook `openstack.yml` + `vars/upstream.yml` used by all DevStack/fullstack boxes |
| `devstack/Ubuntu/ovn/remote_workdir/` | Local SSHFS mount point for editing OpenStack projects on the OVN VM; has its own `AGENTS.md` |

`*_old` and CentOS 7/8 boxes are kept to test older stable releases; they are
expected to age badly and are not the default choice for new work.

## Skills

Project skills live in `.agents/skills/`:

- `deploy-devstack` — maps a request like "deploy ml2/ovn single node devstack"
  to the right box directory, brings the VM up (without re-provisioning a halted
  one), checks whether DevStack is already running, and runs `stack.sh` on the
  controller before any compute nodes. Handles non-DevStack boxes by only
  running `vagrant up`.

More skills (local development/testing inside the boxes) will be added here.

## Host requirements

- Vagrant 2.x, plus `vagrant-libvirt` (main path) and optionally VirtualBox
- `ansible` on the host (Vagrant's Ansible provisioner runs it locally)
- The external roles repo checked out on `roles_path` (see above)
- `/tmp/vault_pass` containing the Ansible vault password for boxes that set
  `ansible.vault_password_file`
- Enough RAM: most boxes request 6–16 GB and DevStack multinode setups run
  2–4 VMs at once

## Running a box

Always work from the directory that holds the `Vagrantfile`:

```sh
cd devstack/Ubuntu/ovn
vagrant status
vagrant up                 # create + provision (slow, 10-40 min)
vagrant ssh                # log in
vagrant halt               # shut down, keep the VM
vagrant destroy            # DELETE the VM and its disks
```

Re-run provisioning after a config change:

```sh
vagrant provision
# or, from scratch:
vagrant destroy -f && vagrant up
```

Safe, read-only commands an agent may run without asking: `vagrant status`,
`vagrant ssh-config`, `vagrant validate`, `git status`, `git diff`,
`virsh list --all`.

`vagrant up`, `vagrant destroy`, `vagrant reload`, and re-provisioning are
expensive and destructive — confirm with the user first.

Boxes with `ansible.ask_vault_pass = true` prompt interactively for the vault
password, so they cannot be brought up unattended. The `multinode_*` boxes read
`/tmp/vault_pass` instead, but still require that file to exist.

## Provisioning notes

- All DevStack/fullstack scenarios call `openstack_provisioning/openstack.yml`
  and differ only in `ansible.extra_vars`:
  `vm_type` (`devstack` | `fullstack`), `l2_agent` (`openvswitch` | `ovn` |
  `linuxbridge`), `l3_mode` (`dvr` | `dvr_snat` | `legacy`), `topology`
  (`allinone` | `multinode`), `service_host` (controller IP on compute nodes).
- `branch` in `openstack.yml` selects the OpenStack release; `vars/upstream.yml`
  maps it to `stable/<branch>` per project (e.g. `Epoxy`).
- `/vagrant` synced folders are disabled everywhere. Edit code inside the VM,
  over SSHFS (see `devstack/Ubuntu/ovn/remote_workdir/AGENTS.md`), or via the
  project checkouts under `/opt/stack`.
- SSH agent forwarding is on, so git/gerrit pushes from the VM use the host key.
- Each directory's `ansible.cfg` is a symlink to the repo-root one; keep it that
  way when adding a new scenario.
- Vault-encrypted variables and anything under `files/gpg` are personal secrets.
  Never print, copy, or commit them. `fedora-vm/files` is git-ignored for this
  reason.

## Network map

Private host-only ranges are deliberately per-family, which makes it easy to see
where a box came from:

| Range | Used by |
| --- | --- |
| `10.100.0.x` | CentOS DevStack boxes, Packstack |
| `10.110.0.x` | Plain dev VMs (`generic-centos-vm`, `fedora-vm`) |
| `10.120.0.x` | Ubuntu DevStack and fullstack boxes |
| `10.130.0.x` | TripleO |
| `10.220.0.x` | `fullstack/Centos` |

Interface names in `extra_vars` follow the image: `eth1` for Ubuntu/generic
boxes, `ens6` for CentOS Stream/Fedora cloud images.

## Editing conventions

- One `Vagrantfile` per scenario; keep the existing structure — memory/CPU
  constants at the top, a `private_network` with a fixed IP, matching `libvirt`
  and `virtualbox` provider blocks, then the Ansible provisioner with
  `extra_vars`.
- New scenario means a new directory with a `Vagrantfile` and an `ansible.cfg`
  symlink; update the table above when you add one.
- Commit messages here are short and descriptive ("Update ubuntu image in
  multinode boxes"). Do not reformat or modernise unrelated `Vagrantfile`
  boilerplate.
- The working tree may contain uncommitted experiments (new boxes, removed old
  ones). Inspect `git status` and `git diff` before assuming a file is stale;
  never reset, checkout, or clean on the user's behalf.
