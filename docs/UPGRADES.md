# Upgrade policy before upstream acceptance

The durable fix is upstream inclusion in `pve-storage`, `pve-manager`, and
`pve-docs`. Until that happens, an official Proxmox package can overwrite the
patched files even when the plugin API remains compatible.

Do not solve this with a permanent package hold. Holding an old
`libpve-storage-perl` while the rest of Proxmox advances can create a less
visible API mismatch and can withhold security and correctness fixes.

## Release process

For every Proxmox update that changes `libpve-storage-perl` or `pve-manager`:

1. Fetch the exact upstream source tags or commits used by the candidate
   packages.
2. Rebase the small patch series and review every conflict, plugin API change,
   schema change, and changed caller contract.
3. Build versions newer than the official candidates, for example
   `9.1.7+neatech1`, and publish both packages in the cluster's signed private
   APT repository.
4. Run the complete upstream suites, the `zfsnvme` unit tests, package lint,
   two-path activation, path-loss recovery, both-path recovery, snapshot and
   clone lifecycle, offline resize, and live migration before promotion.
5. Upgrade one drained node. Confirm the storage is active, every expected
   portal is `live`, every controller has the expected `host_iface` and source
   address, and a scratch guest can perform verified I/O. Then continue one
   node at a time.

If a new official package already contains `zfsnvme`, the guard accepts it by
inspecting package contents rather than relying on a vendor version suffix.

## Transaction guard

Install the guard on every node:

```text
sudo ./tools/install-upgrade-guard.sh
```

APT passes every pending package to the guard before invoking dpkg. When a
`zfsnvme:` section exists in `/etc/pve/storage.cfg`, the guard rejects a
`libpve-storage-perl` package without the native backend, the cluster Host NQN
allow-list and publish-after-ACL hardening; a `pve-manager` package without the
matching UI; or a `pve-docs` package without the operator documentation. The
transaction stops before files change.

The guard deliberately does not intercept a manual `dpkg -i`; inspect manual
packages first:

```text
sudo PVE_ZFSNVME_GUARD_FORCE=1 \
  /usr/local/sbin/pve-zfsnvme-upgrade-guard package1.deb package2.deb
```

An emergency bypass exists, but it can remove the storage schema from running
workers and is not a normal upgrade path:

```text
sudo PVE_ZFSNVME_ALLOW_UNSAFE_UPGRADE=1 apt ...
```

Remove the guard only after all supported repositories ship the backend and
UI, or after the storage has been decommissioned:

```text
sudo ./tools/install-upgrade-guard.sh --uninstall
```
