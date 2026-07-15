# NVMe/TCP lab harnesses

These files reproduce destructive qualification scenarios. Run them only on
dedicated scratch volumes and lab nodes. They require root, `fio`, `nvme-cli`,
`iptables`, and native NVMe multipath. Always verify the volume ID, addresses,
interfaces, VMID, quorum, and watchdog before execution.

## Performance and all-path loss

`perf-100m.sh <volume-id> [output-directory]` compares each path at 100 Mbit/s,
both shaped paths, and the unshaped pair. The volume is overwritten. Interface,
target address, rate, and runtime defaults can be overridden with environment
variables documented at the top of the script.

`fail-fast-policy.sh <volume-id> [output-directory]` verifies the configured
kernel fail-fast behavior by blackholing both NVMe/TCP flows. It refuses to run
when `fast_io_fail_tmo` is `off`, expects `fio` to receive a block error, and
restores the firewall rules through an exit trap. The caller owns allocation
and deletion of the scratch volume. A block error is the expected PASS outcome
for this policy test; do not run it against a guest disk.

`discard-scratch-volume.sh` exercises thin/discard reclamation and contains its
own scratch-volume guard.

## Live quorum-partition test

`ha-qemu-monitor.sh VMID OUTPUT [INTERVAL]` samples the QEMU process state so
source and survivor timelines can be compared for overlap.

`ha-corosync-partition.sh apply|remove PEER_IP QDEVICE_IP [TAG]` installs or
removes only tagged Corosync-peer and QDevice firewall rules. It intentionally
does not block management or NVMe/TCP data networks.

The two systemd units make the injected topology survive the isolated node's
watchdog reboot:

- `pve-nvme-ha-partition.service` reapplies the partition before Corosync and
  HA start. Its addresses are specific to the documented lab and must be edited
  for another topology.
- `nvmetestbr.service` recreates the lab-only guest bridge used by the HA
  scratch VM.

Before the test, install the partition helper as
`/usr/local/sbin/ha-corosync-partition`, install and enable the units only on
the node that will be isolated, start monitors on both nodes, and confirm the
survivor has quorum through QDevice. After the survivor starts the guest,
disable and remove both units and helper, remove all tagged firewall rules, and
purge the scratch VM and zvol. Confirm the control VM, quorum, both paths, and
target namespace inventory before declaring cleanup complete.
