# Encrypted VPS Backups

Public repository for encrypted server backups.

Only commit encrypted archives (`*.tar.zst.age`), checksums, manifests, scripts, and non-secret host configs.

## Restore example

```bash
age -d -i age-identity.txt backups/ociarm0/latest.tar.zst.age > restore.tar.zst
tar --zstd -tf restore.tar.zst
```

Keep the age private key outside this repository and outside servers.
