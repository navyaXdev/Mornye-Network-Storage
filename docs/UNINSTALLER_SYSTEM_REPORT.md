# Mornye Network Storage — Secure Uninstaller & Purge System (delete.sh)

**Specification Compliance & Implementation Report**  
**Module**: `delete.sh`, `tests/test_uninstaller.sh`, `mornye.sh` (v3.2.0)  
**Date**: November 12, 2026  
**Status**: **VERIFIED & PRODUCTION OPERATIONAL (15/15 Uninstaller Tests Passed)**

---

## 1. Executive Summary

A secure, comprehensive, and isolated uninstaller system has been implemented for Mornye Network Storage via the root-level script:
```bash
./delete.sh
```

The uninstaller provides two distinct operational modes:
1. **Mode A: Safe Uninstall (`./delete.sh` / `./mornye.sh uninstall`)**: Stops and removes Mornye-owned Docker containers, images, bridge networks, services, and background workers while **strictly preserving user databases, music storage, backups, and configurations**.
2. **Mode B: Complete Purge (`./delete.sh --purge`)**: Permanently removes all Mornye-owned resources including database files, user storage, music files, backups, logs, and configurations. It is guarded by a mandatory typed token: `DELETE MORNYE DATA`. Simple `y` or `yes` confirmations are rejected.

---

## 2. Resource Isolation & Safety Invariants

| Target / Component | Action in Safe Uninstall | Action in Complete Purge | Safety Guarantee |
|---|---|---|---|
| **SONG Bridge (`mornye-storage.service`)** | **PRESERVED** | **PRESERVED** | **100% PROTECTED**. PID 13951 on port 8000 is never stopped or altered. |
| **Cloudflare Tunnel (`mornye-tunnel.service`)** | **PRESERVED** | **PRESERVED** | **100% PROTECTED**. Running from `/home/spidyno/.song/program/cloudflare/tunnel` on port 20241. |
| **Navidrome Music Server** | **PRESERVED** | **PRESERVED** | Unit `navidrome.service` and port 4533 are untouched. |
| **System Web Servers & DBs** | **PRESERVED** | **PRESERVED** | Nginx, Apache, Caddy, PostgreSQL, MySQL remain untouched. |
| **Foreign Docker Containers** | **PRESERVED** | **PRESERVED** | Containers not labeled with Mornye compose project or named `mornye-*` are preserved. |
| **Foreign Docker Images & Volumes** | **PRESERVED** | **PRESERVED** | Unrelated images and volumes are never pruned. Global prune commands are prohibited. |
| **System Packages** | **PRESERVED** | **PRESERVED** | Docker Engine and Docker Compose are never removed. |
| **User Database (`database/`)** | **PRESERVED** | **PURGED** | Preserved in Safe mode; purged only after typing `DELETE MORNYE DATA`. |
| **User Storage (`storage/`)** | **PRESERVED** | **PURGED** | Preserved in Safe mode; purged only after typing `DELETE MORNYE DATA`. |
| **User Backups (`backups/`)** | **PRESERVED** | **PURGED** | Preserved in Safe mode; purged only after typing `DELETE MORNYE DATA`. |
| **Mornye Container (`mornye-webdav`)** | **REMOVED** | **REMOVED** | Stopped and deleted via Docker Compose / CLI. |
| **Mornye Image (`mornye-webdav:latest`)** | **REMOVED** | **REMOVED** | Cleaned from local Docker images. |
| **Mornye Network (`mornye-net`)** | **REMOVED** | **REMOVED** | Bridge network removed. |
| **Runtime Temporary Files (`run/*`)** | **CLEANED** | **PURGED** | Quick tunnel PID and temporary files cleaned. |

---

## 3. Strict Safety & Path Boundary Enforcement

The uninstaller incorporates multi-layered defensive checks:

1. **System Critical Roots Protection (`validate_safe_path`)**:
   Refuses to delete system directories (`/`, `/home`, `/root`, `/etc`, `/var`, `/usr`, `/opt`, `/tmp`, `/boot`, `/sys`, `/proc`, `/dev`, `/bin`, `/sbin`, `/lib`, `/lib64`, `/mnt`).
2. **User Home Directory Protection**:
   Explicitly checks and refuses deletion if target path matches `$HOME` or `/home/<user>`.
3. **Symlink Escape Protection (`safe_remove_path`)**:
   Symbolic links are removed without following the link or touching external targets.
4. **Idempotent Execution**:
   Running `delete.sh` repeatedly on a partial or already-uninstalled directory produces exit code 0 without errors or damage.

---

## 4. Test Suite Verification Results (`tests/test_uninstaller.sh`)

The test suite validates 15 distinct operational and edge-case scenarios:

```
======================================================================
          MORNYE UNINSTALLER & RESOURCE PURGE TEST SUITE              
======================================================================

[Test 1/15] Dry-Run Mode Simulation
  -> [PASS] Dry run executed successfully with zero system modifications

[Test 2/15] Safe Uninstall Data Preservation
  -> [PASS] Safe uninstall preserved database, storage, backups, and config while cleaning run files

[Test 3/15] Purge Confirmation Token Enforcement
  -> [PASS] Purge strictly rejected 'yes' input and preserved database intact

[Test 4/15] Complete Purge with Valid 'DELETE MORNYE DATA' Token
  -> [PASS] Complete purge successfully removed all database, storage, backups, and config

[Test 5/15] Pre-Purge Safety Backup Archive
  -> [PASS] Pre-purge backup created valid tar.gz containing database and audio files

[Test 6/15] SONG Bridge Protection Invariant
  -> [PASS] Explicitly identified and protected SONG Bridge (mornye-storage.service on port 8000)

[Test 7/15] Foreign Docker Container & Volume Isolation
  -> [PASS] Preserved foreign Docker containers (navidrome, postgres) while targeting mornye-webdav

[Test 8/15] Missing Docker Environment Handling
  -> [PASS] Handled missing Docker CLI gracefully without crash

[Test 9/15] Docker Permission Denied Handling
  -> [PASS] Handled Docker socket permission denial safely during discovery

[Test 10/15] Shared Cloudflare Ingress Isolation
  -> [PASS] Isolated and stripped Mornye ingress while preserving SONG Bridge (8000) and Navidrome (4533)

[Test 11/15] Dedicated Cloudflare Local Config Handling
  -> [PASS] Preserved local Cloudflare tunnel configuration in Safe Uninstall mode

[Test 12/15] System Root & Critical Directory Protection
  -> [PASS] validate_safe_path strictly rejected '/', '/etc', '/home', '/var', '/usr', and user home

[Test 13/15] Symlink Escape Protection
  -> [PASS] Removed symlink without touching or deleting external target file

[Test 14/15] Idempotency & Repeated Execution Safety
  -> [PASS] delete.sh executed idempotently 3 times in succession with exit code 0

[Test 15/15] Post-Uninstall Removal Report & Secret Privacy
  -> [PASS] Generated uninstall report at logs/uninstall/uninstall-*.txt with zero secret exposure

======================================================================
TEST SUITE SUMMARY: Total: 15 | Passed: 15 | Failed: 0 (100% PASS RATE)
======================================================================
```

---

## 5. CLI Commands Reference

```bash
# 1. Safe uninstall (preserves music, database, backups)
sudo ./delete.sh
# or via CLI
./mornye.sh uninstall

# 2. Complete purge (permanently deletes all data)
sudo ./delete.sh --purge

# 3. Dry-run simulation (makes 0 changes to host)
sudo ./delete.sh --dry-run
sudo ./delete.sh --purge --dry-run

# 4. Create standalone safety backup archive
sudo ./delete.sh --backup /tmp/my_mornye_backup.tar.gz

# 5. Non-interactive automated execution (for scripts/CI)
sudo ./delete.sh -y
sudo ./delete.sh --purge --skip-backup --confirm="DELETE MORNYE DATA"
```

