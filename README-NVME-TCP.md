# Native ZFS over NVMe/TCP for Proxmox VE

This branch adds a native `zfsnvme` storage type to `pve-storage`. It keeps the
ZFS lifecycle used by the existing ZFS-over-iSCSI backend, but publishes each
owned zvol as an NVMe namespace and maps it through Linux native NVMe
multipath on every Proxmox node.

Implemented lifecycle operations include thin zvol allocation, free,
snapshots, rollback, templates, linked clones, offline resize, activation,
deactivation, storage status, and shared-storage live migration. Namespace
identity is persisted in ZFS user properties, and guests use the stable
`/dev/disk/by-id/nvme-uuid.*` path rather than controller or namespace numbers.

## Design

- The Proxmox node remains the control-plane client. ZFS and NVMe target
  changes execute on the storage server through the existing ZFS SSH channel.
  Connected guest I/O does not depend on that SSH path, but capacity reporting
  and lifecycle mutations do. Production deployments should point `server` at
  a redundant management DNS name or VIP for the storage appliance.
- The target implementation uses the Linux configfs `nvmet` API directly and
  serializes mutations with `/run/lock/pve-nvmet.lock`.
- `nvme-host-nqns` lists every authorized cluster Host NQN. After a target
  reboot, the first node restores the complete ACL and DHCHAP set before the
  port links become reachable. `allow_any_host` is never enabled.
- DH-HMAC-CHAP keys are stored in pmxcfs with mode `0600`, sent to `nvme-cli`
  through a protected libnvme JSON file, and never placed on a process command
  line.
- Portals are paired positionally with explicit local interfaces. A controller
  connected through the wrong interface is replaced one path at a time. Every
  node verifies that all configured interfaces exist before changing target
  state.
- Existing zvols are not adopted implicitly. The provider checks ownership,
  subsystem NQN, namespace ID, UUID, model, and deterministic serial before it
  mutates target state.
- Storage removal requires the owned ZFS dataset to be empty and also refuses
  to disconnect the local subsystem while a process or kernel block holder is
  using any namespace.

## Required production baseline

The storage server needs OpenZFS, `nvmet`, `nvmet-tcp`, configfs, one isolated
TCP portal per failure domain, and the SSH privileges already required by the
Proxmox ZFS-over-iSCSI backend. Every Proxmox node needs `nvme-cli`,
`nvme-tcp`, native NVMe multipath enabled, a unique `/etc/nvme/hostnqn`, and
identically named data interfaces.

Disable cloud-init device discovery on a dedicated target after provisioning.
Otherwise a guest cloud-init ZVOL labelled `cidata` can be mistaken for the
target host's own NoCloud datasource during reboot.

Use redundant switches and subnets. DH-HMAC-CHAP authenticates hosts but does
not encrypt payloads; this implementation does not configure NVMe/TCP TLS.
Storage networks therefore need physical or cryptographic isolation appropriate
for the threat model.

`shared 1` relies on Proxmox cluster locking and fencing to prevent unrelated
hosts from writing the same guest disk. Enterprise deployment requires tested
fencing, quorum, time synchronization, backups, and recovery procedures.

All-path failure policy is explicit. By default, `nvme-fast-io-fail-tmo` is
unset and the kernel can queue guest I/O for the configured
`nvme-ctrl-loss-tmo` (600 seconds by default), favoring transparent recovery.
Set the optional fast-I/O-fail timeout when a workload must receive a prompt
block error instead of a long stall. The backend rejects a fail-fast timeout
longer than a finite controller-loss timeout.

## Current limitation

Online block-device resize is rejected before the zvol is changed. The Proxmox
QEMU path currently issues `block_resize`, which cannot resize a host block
device opened through `host_device`. Stop the VM, resize it, and start it again.
All other lifecycle operations listed above have been exercised in the lab.

See [docs/VALIDATION.md](docs/VALIDATION.md) for the evidence collected and
[docs/UPGRADES.md](docs/UPGRADES.md) for the supported upgrade process.
The complete engineering narrative is in
[docs/ENGINEERING-REPORT-20260802.es.md](docs/ENGINEERING-REPORT-20260802.es.md), with the same
results available as machine-readable
[JSON](docs/validation-results.json).

## Companion upstream branches

- Backend and validation: https://github.com/joaquinv98/pve-storage/tree/feature/zfs-nvme-tcp
- Proxmox VE web UI: https://github.com/joaquinv98/pve-manager/tree/feature/zfs-nvme-tcp
- Administrator documentation: https://github.com/joaquinv98/pve-docs/tree/feature/zfs-nvme-tcp

Proxmox accepts code contributions as patch series on `pve-devel`; the GitHub
forks are public review and reproducibility mirrors, not the canonical merge
queue.
