# Validation record

Cut-off: 2026-08-02. The canonical structured record is
[`validation-results.json`](validation-results.json); the detailed reasoning is
in [`ENGINEERING-REPORT-20260802.es.md`](ENGINEERING-REPORT-20260802.es.md).

## Environment

- Two-node nested Proxmox VE 9.2 cluster with QDevice and watchdog fencing.
- PVE kernel 7.0.14-8-pve, `nvme-cli` 2.13, native NVMe multipath.
- Ubuntu target kernel 6.8.0-136, OpenZFS 2.2.2 and `nvme-cli` 2.8.
- Two isolated NVMe/TCP networks and a separate guest network.
- Real Debian 13 guest, VMID 920, booting from the shared NVMe namespace.
- DH-HMAC-CHAP and a complete two-node `nvme-host-nqns` allow-list.

## Build gates

- Current upstream fetched for all three repositories; every feature branch is
  zero commits behind its corresponding official `master`.
- Full `pve-storage` test/build and package lint passed.
- 46 focused `zfsnvme` assertions passed.
- `pve-manager make check`, including Biome over 376 files, passed.
- `pve-docs`, `pve-doc-generator`, and mediawiki packages built and linted.

## Functional and integrity gates

- Thin allocation, 1 GiB write allocation, and full discard reclamation.
- Snapshot/rollback with exact checksum restoration.
- Template, linked clone and full clone; linked-clone writes remained isolated.
- Offline 4-to-5 GiB resize propagated to target and both nodes.
- Online resize rejected before mutating the zvol.
- Sixteen parallel allocation attempts from both nodes; the single pmxcfs lock
  timeout was retried. All 19 observed identities had unique NSID and UUID,
  followed by complete scratch cleanup.
- A foreign zvol carrying a valid but different subsystem NQN was absent from
  `pvesm list`, remained absent from configfs after a real reconcile, and was
  destroyed without affecting owned namespaces.
- Real ANA `optimized -> non-optimized -> optimized` transition under 370,259
  operations and 1.516 GB written, with zero fio errors and zero short I/O.

## Path performance and fault injection

Each path was shaped independently to 100 Mbit/s:

| Scenario | Throughput | IOPS |
|---|---:|---:|
| Path A | 11.94 MB/s | 83.53 |
| Path B | 11.99 MB/s | 83.98 |
| A + B | 23.87 MB/s | 174.25 |
| A + B unshaped | 91.47 MB/s | 691.23 |

The dual shaped result was 1.999 times path A. This validates use of both paths,
not production hardware sizing.

- Path A cut for 12 seconds: no fio error.
- Path B cut for 12 seconds: no fio error.
- Both paths cut for 15 seconds with queue policy: resumed with valid checksum.
- Long both-path outage under explicit fail-fast: expected EIO, two live paths
  after recovery, and valid post-recovery checksum.

## Migration and HA

- node1 -> node2: 69 ms downtime, 7.775 s total.
- node2 -> node1: 124 ms downtime, 8.375 s total.
- migration to a destination with one path down: 645 ms downtime, 9.645 s
  total; path restored afterward.
- Hard loss of the active PVE node: QDevice kept survivor quorum, fencing was
  acknowledged before restart, QEMU restarted at about 143 s and guest ping at
  151 s.
- Live corosync/QDevice partition with data paths still available: isolated
  source self-fenced around 59 s. QEMU sampling every 200 ms showed a 91.151 s
  writer gap and no writer overlap.

## Target reboot qualification

The first attempt exposed a provisioning issue: cloud-init on the storage host
consumed the guest's `cidata` ZVOL. The target now disables cloud-init discovery
after bootstrap and persists `nvmet_tcp`, hostname, SSH identity, and the ZFS
pool cache.

The next attempt exposed a code race: port links became reachable before every
Host NQN ACL. The initiator received `host not allowed`, removed controllers and
QEMU entered `io-error`. The guest disk was snapshotted and repaired offline;
the failure is retained in the report.

The backend now prepares ports privately, restores every configured Host NQN
and DHCHAP key, reconciles namespaces, and publishes port links last. Repeating
the reboot under verified guest I/O produced:

- target ping down/up cycle 18.3 seconds;
- 6 namespaces, 2 ACLs and 2 port links reconstructed;
- both controllers on both nodes reconnected;
- no `host not allowed`, controller removal, EIO, or QEMU pause;
- guest loop advanced from 8 to 82 iterations and finished with valid SHA-256.

## Upgrade gate

APT attempted to replace the local same-version backend, manager, and docs with
official artifacts. The transaction guard accepted the complete custom set and
rejected all three official artifacts. A real `apt-get -y full-upgrade` exited
100 before dpkg changed files; storage remained active. Permanent package holds
are not used.

## Remaining production qualification

The code is a lab-qualified release candidate, not a hardware certification.
Before rollout, run at least a 72-hour mixed-I/O soak on the intended platform,
capture p50/p95/p99/p99.9 and workload RTO, inject physical NIC/cable/switch
failures, exercise near-full/full-pool behavior, perform a complete backup
restore, validate a rolling upgrade with exact candidates, decide TLS versus
physical isolation, and complete upstream review.
