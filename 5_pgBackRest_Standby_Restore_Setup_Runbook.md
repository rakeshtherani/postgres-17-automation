# pgBackRest Standby Restore & Setup Runbook
## Creating New Standby Servers from pgBackRest Backups

---

## Document Information

| Field | Value |
|-------|-------|
| Document Version | 1.1 |
| Last Updated | 2026-01-17 |
| PostgreSQL Version | 17.x |
| pgBackRest Version | 2.55.1 |
| Target OS | Amazon Linux 2023 |
| Script Name | 6_pgbackrest_standby_setup.sh |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Prerequisites and Requirements](#3-prerequisites-and-requirements)
4. [Pre-Deployment Checklist](#4-pre-deployment-checklist)
5. [Restore Options](#5-restore-options)
6. [Deployment Procedure - EBS Restore](#6-deployment-procedure---ebs-restore)
7. [Deployment Procedure - S3 Restore](#7-deployment-procedure---s3-restore)
8. [Point-in-Time Recovery (PITR)](#8-point-in-time-recovery-pitr)
9. [Operations Procedures](#9-operations-procedures)
10. [Troubleshooting Guide](#10-troubleshooting-guide)
11. [Appendix](#11-appendix)
12. [Complete Execution Output Logs](#12-complete-execution-output-logs)

---

## 1. Executive Summary

### Purpose
This runbook provides step-by-step instructions for creating new PostgreSQL 17 standby servers using pgBackRest backups. Supports both EBS snapshot and S3 restore methods with Point-in-Time Recovery (PITR) capability.

### Scope
- Restore from EBS snapshots (fast, local)
- Restore directly from S3 bucket (no snapshot needed)
- Point-in-Time Recovery to specific timestamps
- Configure new server as streaming replication standby
- Register with repmgr cluster

### Key Features

| Feature | Description |
|---------|-------------|
| EBS Restore | Fast recovery from EBS snapshots |
| S3 Restore | Direct restore from S3 without local snapshot |
| PITR | Recover to specific point in time |
| Auto-Configuration | Automatic replication and repmgr setup |
| Flexible Recovery | Multiple recovery target options |

### Use Cases

| Scenario | Restore Method | Recovery Target |
|----------|----------------|-----------------|
| Add new standby | EBS or S3 | latest |
| Replace failed standby | EBS | latest |
| Disaster recovery | S3 | latest |
| Data recovery (accidental delete) | S3 | time (PITR) |
| Clone for testing | EBS or S3 | immediate |

---

## 2. Architecture Overview

### 2.1 Restore Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    pgBackRest Standby Restore Architecture                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  RESTORE SOURCE OPTIONS:                                                     │
│                                                                              │
│  ┌─────────────────┐                      ┌─────────────────────────┐       │
│  │  EBS Snapshot   │───── Create ────────►│   New EBS Volume        │       │
│  │  (snap-xxx)     │       Volume         │   /backup/pgbackrest    │       │
│  └─────────────────┘                      └───────────┬─────────────┘       │
│                                                       │                      │
│          OR                                           │                      │
│                                                       ▼                      │
│  ┌─────────────────┐                      ┌─────────────────────────┐       │
│  │   S3 Bucket     │───── Direct ────────►│   NEW STANDBY SERVER    │       │
│  │  (s3://xxx)     │      Restore         │                         │       │
│  └─────────────────┘                      │   ┌─────────────────┐   │       │
│                                           │   │  PostgreSQL 17  │   │       │
│                                           │   │  (Restored DB)  │   │       │
│  RECOVERY TARGETS:                        │   └────────┬────────┘   │       │
│                                           │            │            │       │
│  • latest    - Most recent backup         │            │ Streaming  │       │
│  • time      - Specific timestamp (PITR)  │            │ Replication│       │
│  • immediate - End of backup, no WAL      │            ▼            │       │
│  • name      - Named restore point        │   ┌─────────────────┐   │       │
│  • lsn       - Specific LSN               │   │    PRIMARY      │   │       │
│                                           │   │  10.41.241.74   │   │       │
│                                           │   └─────────────────┘   │       │
│                                           │                         │       │
│                                           └─────────────────────────┘       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Server Configuration

| Role | IP Address | Instance ID | Purpose |
|------|------------|-------------|---------|
| Primary | 10.41.241.74 | i-052b680cf24be321e | Read/Write |
| Existing Standby | 10.41.241.191 | i-013fe40421853b6b0 | Backup Source |
| New Standby | (user-specified) | (new instance) | Additional Replica |

### 2.3 Restore Flow

```
EBS Restore Flow:
──────────────────────────────────────────────────────────────────────────
Step 1: Find Latest Snapshot
         └── Query EC2 for snapshots tagged with stanza name

Step 2: Create Volume from Snapshot
         └── Create new gp3 volume with 16000 IOPS

Step 3: Attach Volume to New Server
         └── Attach as /dev/xvdb, mount at /backup/pgbackrest

Step 4: Verify pgBackRest Configuration
         └── Create /etc/pgbackrest/pgbackrest.conf

Step 5: Restore Database
         └── pgbackrest restore --delta

Step 6: Setup Replication Slot
         └── Create physical replication slot on primary

Step 7: Configure and Start Standby
         └── Start PostgreSQL, register with repmgr
──────────────────────────────────────────────────────────────────────────

S3 Restore Flow:
──────────────────────────────────────────────────────────────────────────
Step 1: Configure S3 Access
         └── Create pgbackrest.conf with S3 repo settings

Step 2: Verify S3 Backups
         └── pgbackrest info to list available backups

Step 3: Restore Database
         └── pgbackrest restore (with PITR options if needed)

Step 4: Setup Replication Slot
         └── Create physical replication slot on primary

Step 5: Configure and Start Standby
         └── Start PostgreSQL, register with repmgr
──────────────────────────────────────────────────────────────────────────
```

---

## 3. Prerequisites and Requirements

### 3.1 Hardware Requirements

| Resource | Minimum | Recommended | Notes |
|----------|---------|-------------|-------|
| CPU | 2 cores | 4+ cores | Restore is CPU-intensive |
| Memory | 8 GB | 16 GB | Match primary configuration |
| Storage | 50 GB | 100+ GB | Data directory |
| Network | 1 Gbps | 10 Gbps | S3 restore bandwidth |

### 3.2 Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| PostgreSQL | 17.x | Must match primary version |
| pgBackRest | 2.55.1 | Backup/restore tool |
| repmgr | 5.5.0 | Cluster management |
| AWS CLI | 2.x | EBS/S3 operations |

### 3.3 New Standby Server Requirements

- [ ] Fresh Amazon Linux 2023 instance
- [ ] PostgreSQL 17 installed (but not initialized)
- [ ] Data directory exists: `/dbdata/pgsql/17/data`
- [ ] Root SSH access from deployment machine
- [ ] Network connectivity to primary (port 5432)

### 3.4 Required Information

| Parameter | Example | Description |
|-----------|---------|-------------|
| NEW_STANDBY_IP | 10.41.241.200 | IP of new standby server |
| NEW_NODE_ID | 3 | Unique repmgr node ID |
| NEW_NODE_NAME | standby2 | Unique node name |
| STATE_FILE | /root/pgbackrest_standby_backup_state.env | From backup setup |

---

## 4. Pre-Deployment Checklist

### 4.1 Verify Backup Availability

```bash
# Check EBS snapshots
aws ec2 describe-snapshots \
    --owner-ids self \
    --filters "Name=tag:Stanza,Values=pg17_cluster" \
    --query 'Snapshots[?State==`completed`].[SnapshotId,StartTime,Description]' \
    --output table \
    --region ap-northeast-1

# Expected output:
+------------------------+---------------------------+----------------------------------------+
|       SnapshotId       |        StartTime          |             Description                |
+------------------------+---------------------------+----------------------------------------+
|  snap-03327404502cd8b25|  2026-01-14T08:19:30.000Z | pgbackrest-standby-pg17_cluster-full.. |
+------------------------+---------------------------+----------------------------------------+
```

```bash
# Check S3 backups (from existing standby)
sudo -u postgres pgbackrest --stanza=pg17_cluster info

# Expected output:
stanza: pg17_cluster
    status: ok
    db (current)
        full backup: 20260114-081813F
            timestamp start/stop: 2026-01-14 08:18:13 / 2026-01-14 08:19:25
```

### 4.2 Verify New Standby Server

```bash
# Test SSH connectivity
ssh root@NEW_STANDBY_IP "hostname"

# Verify PostgreSQL is installed
ssh root@NEW_STANDBY_IP "psql --version"
# Expected: psql (PostgreSQL) 17.x

# Verify data directory exists
ssh root@NEW_STANDBY_IP "ls -la /dbdata/pgsql/17/data"
```

### 4.3 Verify Network Connectivity

```bash
# From new standby, test connectivity to primary
ssh root@NEW_STANDBY_IP "nc -zv 10.41.241.74 5432"
# Expected: Connection to 10.41.241.74 5432 port [tcp/postgresql] succeeded!
```

### 4.4 Get State File (If Using EBS)

```bash
# Copy state file from existing standby
scp root@10.41.241.191:/root/pgbackrest_standby_backup_state.env /tmp/

# Verify contents
cat /tmp/pgbackrest_standby_backup_state.env
# Should contain:
# BACKUP_VOLUME_ID=vol-xxx
# LATEST_SNAPSHOT_ID=snap-xxx
# STANZA_NAME=pg17_cluster
```

---

## 5. Restore Options

### 5.1 Comparison of Restore Methods

| Feature | EBS Restore | S3 Restore |
|---------|-------------|------------|
| Speed | Very Fast | Depends on bandwidth |
| Cost | EBS snapshot cost | S3 transfer cost |
| Prerequisites | Snapshot available | S3 bucket access |
| PITR Support | Yes | Yes |
| Network Dependency | Minimal | High |
| Best For | Same-region recovery | Cross-region/DR |

### 5.2 Recovery Target Options

| Target | Usage | Command Option |
|--------|-------|----------------|
| latest | Recover to most recent state | (default) |
| time | Recover to specific timestamp | `--target-time="2026-01-14 08:00:00"` |
| immediate | Recover to backup end, no WAL replay | `--type=immediate` |
| name | Recover to named restore point | `--target-name="before_migration"` |
| lsn | Recover to specific LSN | `--target-lsn="0/3000178"` |

### 5.3 Target Action Options

| Action | Description | Use Case |
|--------|-------------|----------|
| promote | Promote to primary after recovery | Testing, DR failover |
| pause | Pause at recovery target | Verify data before continuing |
| shutdown | Shutdown after reaching target | One-time data extraction |

---

## 6. Deployment Procedure - EBS Restore

### 6.1 Step 1: Download Script

```bash
# Download from S3
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/pgbackrest_standby_setup.sh /tmp/
chmod +x /tmp/pgbackrest_standby_setup.sh
```

### 6.2 Step 2: Configure Environment Variables

```bash
# Set required variables
export PRIMARY_IP="10.41.241.74"
export EXISTING_STANDBY_IP="10.41.241.191"
export NEW_STANDBY_IP="10.41.241.200"    # New standby server IP
export PG_VERSION="17"
export STANZA_NAME="pg17_cluster"
export AWS_REGION="ap-northeast-1"
export AVAILABILITY_ZONE="ap-northeast-1a"
export NEW_NODE_ID="3"
export NEW_NODE_NAME="standby2"

# Set restore source to EBS
export RESTORE_SOURCE="ebs"

# Recovery target (default: latest)
export RECOVERY_TARGET="latest"
```

### 6.3 Step 3: Run with State File

```bash
# Option A: Use state file from backup setup
./pgbackrest_standby_setup.sh --state-file /tmp/pgbackrest_standby_backup_state.env

# Option B: Manually specify snapshot
export LATEST_SNAPSHOT_ID="snap-03327404502cd8b25"
./pgbackrest_standby_setup.sh
```

### 6.4 Step 4: Verify Restore

```bash
# Check new standby status
ssh root@$NEW_STANDBY_IP "sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'"
# Expected: t

# Check replication status on primary
ssh root@$PRIMARY_IP "sudo -u postgres psql -c 'SELECT application_name, state FROM pg_stat_replication;'"

# Check cluster status
ssh root@$NEW_STANDBY_IP "sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf cluster show"
```

### 6.5 Expected Output

```
=== STEP 1: Finding latest snapshot ===
Using snapshot from state file: snap-03327404502cd8b25

=== STEP 2: Creating new volume from latest snapshot ===
New volume created: vol-0abc123def456

=== STEP 3: Attaching volume to new standby server ===
Target instance: i-0xyz789

=== STEP 6: Performing database restore ===
Restore source: ebs
Recovery target: latest
Starting pgBackRest restore...
Restore completed successfully

=== STEP 7: Setting up replication slot on primary ===
Creating replication slot for new standby...
Replication slot setup completed

=== STEP 8: Configuring and starting new standby server ===
PostgreSQL started successfully
Replication established

=== STANDBY SETUP COMPLETED SUCCESSFULLY! ===
```

---

## 7. Deployment Procedure - S3 Restore

### 7.1 Step 1: Configure Environment

```bash
# Set required variables
export PRIMARY_IP="10.41.241.74"
export NEW_STANDBY_IP="10.41.241.200"
export PG_VERSION="17"
export STANZA_NAME="pg17_cluster"
export AWS_REGION="ap-northeast-1"
export NEW_NODE_ID="3"
export NEW_NODE_NAME="standby2"

# Set restore source to S3
export RESTORE_SOURCE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export S3_REGION="ap-northeast-1"
```

### 7.2 Step 2: Run Script

```bash
./pgbackrest_standby_setup.sh
```

### 7.3 S3 Configuration Created

The script creates this pgBackRest configuration on the new standby:

```ini
[pg17_cluster]
pg1-path=/dbdata/pgsql/17/data
pg1-port=5432

[global]
# S3 Repository configuration
repo1-type=s3
repo1-s3-bucket=btse-stg-pgbackrest-backup
repo1-s3-region=ap-northeast-1
repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com
repo1-path=/pgbackrest

# General settings
process-max=8
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest

# Restore settings
delta=y

[global:restore]
process-max=8
```

### 7.4 S3 Restore Timeline

| Phase | Duration | Description |
|-------|----------|-------------|
| Configure S3 | ~30 sec | Create pgBackRest config |
| Verify Access | ~10 sec | Test S3 bucket access |
| Download Base | 5-30 min | Download base backup |
| Apply WAL | 1-15 min | Replay WAL files |
| Configure Replication | ~1 min | Setup streaming |
| Start PostgreSQL | ~30 sec | Bring server online |

---

## 8. Point-in-Time Recovery (PITR)

### 8.1 When to Use PITR

| Scenario | Recovery Target | Example |
|----------|-----------------|---------|
| Accidental DELETE/DROP | time | Recover to just before deletion |
| Application bug | time | Recover to last known good state |
| Compliance requirement | time | Recover to audit point |
| Testing | immediate | Quick recovery without WAL replay |

### 8.2 PITR to Specific Time

```bash
# Set environment variables
export RESTORE_SOURCE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export RECOVERY_TARGET="time"
export TARGET_TIME="2026-01-14 08:00:00"
export TARGET_ACTION="promote"

# Run restore
./pgbackrest_standby_setup.sh
```

### 8.3 PITR Command Generated

```bash
# The script generates this command:
pgbackrest --stanza=pg17_cluster \
    --type=time \
    --target="2026-01-14 08:00:00" \
    --target-action=promote \
    --delta \
    restore
```

### 8.4 List Available Recovery Points

```bash
# On existing standby with pgBackRest configured
sudo -u postgres pgbackrest --stanza=pg17_cluster info --output=json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for stanza in data:
    if stanza.get('backup'):
        for b in stanza['backup']:
            print(f\"Backup: {b.get('label', 'N/A')}\")
            print(f\"  Type: {b.get('type', 'N/A')}\")
            print(f\"  Start: {b.get('timestamp', {}).get('start', 'N/A')}\")
            print(f\"  Stop:  {b.get('timestamp', {}).get('stop', 'N/A')}\")
            print(f\"  WAL Start: {b.get('archive', {}).get('start', 'N/A')}\")
            print(f\"  WAL Stop:  {b.get('archive', {}).get('stop', 'N/A')}\")
            print()
"
```

### 8.5 PITR Recovery Validation

After PITR restore:

```bash
# Check recovery target was reached
ssh root@$NEW_STANDBY_IP "sudo -u postgres psql -c \"SELECT pg_last_xact_replay_timestamp();\""

# Verify data state
ssh root@$NEW_STANDBY_IP "sudo -u postgres psql -c \"SELECT count(*) FROM your_table;\""

# If using target_action=pause, resume recovery
ssh root@$NEW_STANDBY_IP "sudo -u postgres psql -c \"SELECT pg_wal_replay_resume();\""
```

---

## 9. Operations Procedures

### 9.1 Add New Standby to Existing Cluster

```bash
# Quick command sequence
export NEW_STANDBY_IP="10.41.241.200"
export NEW_NODE_ID="3"
export NEW_NODE_NAME="standby2"
export RESTORE_SOURCE="ebs"

./pgbackrest_standby_setup.sh --state-file /root/pgbackrest_standby_backup_state.env

# Verify cluster
ssh root@$PRIMARY_IP "sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf cluster show"
```

### 9.2 Replace Failed Standby

```bash
# Use same node ID and name as failed standby
export NEW_STANDBY_IP="10.41.241.192"  # New server IP
export NEW_NODE_ID="2"                  # Same as failed standby
export NEW_NODE_NAME="standby"          # Same as failed standby
export RESTORE_SOURCE="ebs"

# Remove failed standby from repmgr (on primary)
ssh root@$PRIMARY_IP "sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby unregister --node-id=2"

# Drop old replication slot
ssh root@$PRIMARY_IP "sudo -u postgres psql -c \"SELECT pg_drop_replication_slot('standby_slot');\""

# Run restore
./pgbackrest_standby_setup.sh --state-file /root/pgbackrest_standby_backup_state.env
```

### 9.3 Disaster Recovery (S3 Cross-Region)

```bash
# For cross-region DR, use S3 restore
export NEW_STANDBY_IP="10.42.100.50"  # DR region server
export RESTORE_SOURCE="s3"
export S3_BUCKET="btse-dr-pgbackrest-backup"  # DR bucket (replicated)
export S3_REGION="ap-southeast-1"             # DR region
export PRIMARY_IP="10.42.100.51"              # New primary in DR

./pgbackrest_standby_setup.sh
```

### 9.4 Clone for Testing/Development

```bash
# Use immediate recovery to skip WAL replay
export NEW_STANDBY_IP="10.41.241.250"
export RECOVERY_TARGET="immediate"
export TARGET_ACTION="promote"  # Promote so it's writable

./pgbackrest_standby_setup.sh
```

---

## 10. Troubleshooting Guide

### 10.1 Snapshot Not Found

**Error:**
```
No completed snapshots found for stanza: pg17_cluster
```

**Solution:**
```bash
# List all snapshots
aws ec2 describe-snapshots --owner-ids self --region ap-northeast-1 \
    --query 'Snapshots[*].[SnapshotId,Tags[?Key==`Stanza`].Value|[0],State]' \
    --output table

# Check if stanza tag is correct
# Manually specify snapshot ID
export LATEST_SNAPSHOT_ID="snap-xxxxx"
./pgbackrest_standby_setup.sh
```

### 10.2 S3 Access Denied

**Error:**
```
Cannot access S3 backups
```

**Solution:**
```bash
# Verify S3 bucket exists and is accessible
aws s3 ls s3://your-bucket-name/pgbackrest/

# Check IAM role/credentials
aws sts get-caller-identity

# Verify bucket policy allows access
aws s3api get-bucket-policy --bucket your-bucket-name
```

### 10.3 Restore Failed - Invalid Backup

**Error:**
```
ERROR: [126]: unable to restore backup
```

**Solution:**
```bash
# List available backups
sudo -u postgres pgbackrest --stanza=pg17_cluster info

# Verify backup integrity
sudo -u postgres pgbackrest --stanza=pg17_cluster --set=BACKUP_LABEL verify

# Check repository structure
ls -la /backup/pgbackrest/backup/pg17_cluster/
```

### 10.4 Replication Slot Already Exists

**Error:**
```
ERROR: replication slot "standby2_slot" already exists
```

**Solution:**
```bash
# On primary - drop existing slot
sudo -u postgres psql -c "SELECT pg_drop_replication_slot('standby2_slot');"

# Re-run setup
./pgbackrest_standby_setup.sh
```

### 10.5 PostgreSQL Won't Start After Restore

**Error:**
```
LOG: could not connect to the primary server
```

**Solution:**
```bash
# Check pg_hba.conf on primary allows new standby
ssh root@$PRIMARY_IP "grep $NEW_STANDBY_IP /dbdata/pgsql/17/data/pg_hba.conf"

# Add entry if missing
ssh root@$PRIMARY_IP "echo 'host replication repmgr $NEW_STANDBY_IP/32 trust' >> /dbdata/pgsql/17/data/pg_hba.conf"
ssh root@$PRIMARY_IP "sudo -u postgres psql -c 'SELECT pg_reload_conf();'"

# Check standby can reach primary
ssh root@$NEW_STANDBY_IP "nc -zv $PRIMARY_IP 5432"

# Check replication slot exists
ssh root@$PRIMARY_IP "sudo -u postgres psql -c \"SELECT * FROM pg_replication_slots;\""
```

### 10.6 PITR Failed - WAL Not Found

**Error:**
```
ERROR: WAL segment 000000010000000000000005 was not archived
```

**Solution:**
```bash
# Check available WAL range
sudo -u postgres pgbackrest --stanza=pg17_cluster info --output=json | grep archive

# PITR target must be within WAL archive range
# Adjust TARGET_TIME to be within available range

# Force archive from primary
ssh root@$PRIMARY_IP "sudo -u postgres psql -c 'CHECKPOINT; SELECT pg_switch_wal();'"
```

---

## 11. Appendix

### 11.1 Quick Reference Commands

| Task | Command |
|------|---------|
| List EBS snapshots | `aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:Stanza,Values=pg17_cluster" --region ap-northeast-1` |
| List S3 backups | `sudo -u postgres pgbackrest --stanza=pg17_cluster info` |
| Check cluster status | `sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf cluster show` |
| Check replication | `sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;"` |
| Check recovery mode | `sudo -u postgres psql -c "SELECT pg_is_in_recovery();"` |
| Drop replication slot | `sudo -u postgres psql -c "SELECT pg_drop_replication_slot('slot_name');"` |

### 11.2 Environment Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PRIMARY_IP` | Yes | 10.41.241.74 | Primary server IP |
| `NEW_STANDBY_IP` | Yes | - | New standby server IP |
| `PG_VERSION` | No | 17 | PostgreSQL version |
| `STANZA_NAME` | No | pg17_cluster | pgBackRest stanza |
| `RESTORE_SOURCE` | No | ebs | Restore method (ebs/s3) |
| `S3_BUCKET` | For S3 | - | S3 bucket name |
| `S3_REGION` | For S3 | ap-northeast-1 | S3 bucket region |
| `RECOVERY_TARGET` | No | latest | Recovery type |
| `TARGET_TIME` | For PITR | - | Recovery timestamp |
| `TARGET_ACTION` | No | promote | Post-recovery action |
| `NEW_NODE_ID` | No | 3 | repmgr node ID |
| `NEW_NODE_NAME` | No | standby2 | repmgr node name |

### 11.3 Script Location

```
S3: s3://btse-stg-pgbackrest-backup/scripts/pgbackrest_standby_setup.sh
```

### 11.4 Configuration Files Created

| File | Location | Purpose |
|------|----------|---------|
| pgBackRest Config | `/etc/pgbackrest/pgbackrest.conf` | Restore configuration |
| repmgr Config | `/var/lib/pgsql/repmgr.conf` | Cluster management |
| PostgreSQL Config | `/dbdata/pgsql/17/data/postgresql.conf` | Standby settings |
| pg_hba.conf | `/dbdata/pgsql/17/data/pg_hba.conf` | Authentication |
| standby.signal | `/dbdata/pgsql/17/data/standby.signal` | Standby mode marker |

### 11.5 Execution Sequence Summary

```
┌────────────────────────────────────────────────────────────────┐
│                    EXECUTION SEQUENCE                           │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  STEP 1: First run pgbackrest_standby_backup_setup.sh          │
│          on existing standby (10.41.241.191)                   │
│          → Creates backups and EBS snapshots                   │
│          → Generates state file                                │
│                                                                 │
│  STEP 2: Then run pgbackrest_standby_setup.sh                  │
│          from deployment machine                               │
│          → Creates new standby from backup                     │
│          → Configures replication                              │
│          → Registers with repmgr cluster                       │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

---

## 12. Complete Execution Output Logs

### 12.1 S3 Restore Mode - Complete Output

This section documents the complete execution output from running the standby restore script with S3 storage mode.

#### Environment Setup

```bash
export RESTORE_SOURCE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export S3_REGION="ap-northeast-1"
export PRIMARY_IP="10.41.241.74"
export EXISTING_STANDBY_IP="10.41.241.191"
export NEW_STANDBY_IP="10.41.241.171"
export NEW_NODE_ID="3"
export NEW_NODE_NAME="standby3"
export RECOVERY_TARGET="latest"
```

#### Execution Output

```
[root@tyo-aws-stg-binary-option-db-0003 tmp]# ./6_pgbackrest_standby_setup.sh

===============================================================================
  pgBackRest Standby Setup Script v2.0
  PostgreSQL 17 with S3 Restore & PITR Support
===============================================================================

[2026-01-16 18:44:19] ℹ️  INFO: Restore source: S3 (bucket: btse-stg-pgbackrest-backup)
[2026-01-16 18:44:19] ℹ️  INFO: No existing state file found
[2026-01-16 18:44:19] ℹ️  INFO: Configuration:
[2026-01-16 18:44:19] ℹ️  INFO:   Primary IP: 10.41.241.74
[2026-01-16 18:44:19] ℹ️  INFO:   Existing Standby IP: 10.41.241.191
[2026-01-16 18:44:19] ℹ️  INFO:   New Standby IP: 10.41.241.171
[2026-01-16 18:44:19] ℹ️  INFO:   PostgreSQL Version: 17
[2026-01-16 18:44:19] ℹ️  INFO:   Stanza Name: pg17_cluster
[2026-01-16 18:44:19] ℹ️  INFO:   AWS Region: ap-northeast-1
[2026-01-16 18:44:19] ℹ️  INFO:   Log File: /tmp/pgbackrest_standby_setup_20260116_184419.log
[2026-01-16 18:44:19] ℹ️  INFO:   State File: /tmp/pgbackrest_standby_state.env

Do you want to proceed with the standby setup? (yes/no): yes
[2026-01-16 18:44:20] Checking prerequisites for standby setup...
[2026-01-16 18:44:22] ℹ️  INFO: PostgreSQL 17 verified on standby server
[2026-01-16 18:44:22] ✅ Prerequisites check completed
[2026-01-16 18:44:22] ℹ️  INFO: S3 restore mode - skipping EBS snapshot/volume steps
```

#### Step 4: Installing pgBackRest

```
[2026-01-16 18:44:22] === STEP 4: Installing pgBackRest on new standby (10.41.241.171) ===
[2026-01-16 18:44:22] Executing on 10.41.241.171: Installing pgBackRest
PostgreSQL installation verified:
psql (PostgreSQL) 17.7
pgBackRest already installed
pgBackRest 2.55.1
Installation verification:
PostgreSQL: /usr/bin/psql
pgBackRest: /usr/bin/pgbackrest
pgBackRest 2.55.1
[2026-01-16 18:44:22] ✅ Command executed successfully on 10.41.241.171
[2026-01-16 18:44:22] ℹ️  INFO: State saved: PGBACKREST_INSTALLED=true
[2026-01-16 18:44:22] ✅ pgBackRest installation completed
```

#### Step 5: Configuring pgBackRest for S3 Restore

```
[2026-01-16 18:44:22] === STEP 5: Configuring pgBackRest for restore on new standby ===
[2026-01-16 18:44:22] Executing on 10.41.241.171: Configuring pgBackRest for restore
Testing pgBackRest configuration...
stanza: pg17_cluster
    status: error (missing stanza path)
pgBackRest configuration and backup data verified successfully
[2026-01-16 18:44:23] ✅ Command executed successfully on 10.41.241.171
[2026-01-16 18:44:23] ℹ️  INFO: State saved: PGBACKREST_CONFIGURED=true
[2026-01-16 18:44:23] ✅ pgBackRest restore configuration completed
```

#### Step 6: Database Restore from S3

```
[2026-01-16 18:44:23] === STEP 6: Checking database status and backup version ===
[2026-01-16 18:44:23] ℹ️  INFO: Latest available backup: none
[2026-01-16 18:44:23] ℹ️  INFO: PostgreSQL data directory exists - checking current state
[2026-01-16 18:44:24] ℹ️  INFO: Current restored backup label: pgBackRest
[2026-01-16 18:44:24] ℹ️  INFO: Standby signal file found - checking if PostgreSQL is running
[2026-01-16 18:44:24] ℹ️  INFO: PostgreSQL service is not running
[2026-01-16 18:44:24] ℹ️  INFO: Current backup (pgBackRest) differs from latest (none)
[2026-01-16 18:44:24] ℹ️  INFO: Will restore latest backup to ensure standby is up-to-date
[2026-01-16 18:44:24] ℹ️  INFO: Performing database restore with latest backup: none
[2026-01-16 18:44:24] === STEP 6: Performing database restore ===
[2026-01-16 18:44:24] ℹ️  INFO: Restore source: s3
[2026-01-16 18:44:24] ℹ️  INFO: Recovery target: latest
[2026-01-16 18:44:24] ℹ️  INFO: Restore command: [2026-01-16 18:44:24] ℹ️  INFO: Restoring to latest available backup
pgbackrest --stanza=pg17_cluster --delta restore
[2026-01-16 18:44:24] ℹ️  INFO: Configuring pgBackRest for S3 restore on 10.41.241.171...
[2026-01-16 18:44:24] Executing on 10.41.241.171: Configuring pgBackRest for S3 restore
```

**S3 Configuration Created:**
```ini
[pg17_cluster]
pg1-path=/dbdata/pgsql/17/data
pg1-port=5432

[global]
# S3 Repository configuration
repo1-type=s3
repo1-s3-bucket=btse-stg-pgbackrest-backup
repo1-s3-region=ap-northeast-1
repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com
repo1-s3-key-type=auto
repo1-path=/pgbackrest/pg17_cluster

# General settings
process-max=8
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest

# Restore settings
delta=y

[global:restore]
process-max=8
```

**S3 Backup Verification:**
```
S3 pgBackRest configuration created
Verifying S3 backup access...
stanza: pg17_cluster
    status: ok
    cipher: none

    db (current)
        wal archive min/max (17): 00000001000000000000000B/00000001000000000000000E

        full backup: 20260116-145747F
            timestamp start/stop: 2026-01-16 14:57:47+00 / 2026-01-16 14:57:54+00
            wal start/stop: 00000001000000000000000E / 00000001000000000000000E
            database size: 47.7MB, database backup size: 47.7MB
            repo1: backup set size: 4.1MB, backup size: 4.1MB
S3 backup access verified
[2026-01-16 18:44:25] ✅ Command executed successfully on 10.41.241.171
[2026-01-16 18:44:25] ✅ S3 restore configuration completed
```

**Performing Restore:**
```
[2026-01-16 18:44:25] Executing on 10.41.241.171: Performing database restore
Cleaning existing data directory...
=== Available backups ===
stanza: pg17_cluster
    status: ok
    cipher: none

    db (current)
        wal archive min/max (17): 00000001000000000000000B/00000001000000000000000E

        full backup: 20260116-145747F
            timestamp start/stop: 2026-01-16 14:57:47+00 / 2026-01-16 14:57:54+00
            wal start/stop: 00000001000000000000000E / 00000001000000000000000E
            database size: 47.7MB, database backup size: 47.7MB
            repo1: backup set size: 4.1MB, backup size: 4.1MB

Starting pgBackRest restore...
Command: pgbackrest --stanza=pg17_cluster --delta restore
2026-01-16 18:44:25.635 P00   INFO: restore command begin 2.55.1: --delta --exec-id=77342-e4679ab9 --log-level-console=info --log-level-file=detail --log-path=/var/log/pgbackrest --pg1-path=/dbdata/pgsql/17/data --process-max=8 --repo1-path=/pgbackrest/pg17_cluster --repo1-s3-bucket=btse-stg-pgbackrest-backup --repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com --repo1-s3-key-type=auto --repo1-s3-region=ap-northeast-1 --repo1-type=s3 --stanza=pg17_cluster
2026-01-16 18:44:25.635 P00   WARN: --delta or --force specified but unable to find 'PG_VERSION' or 'backup.manifest' in '/dbdata/pgsql/17/data' to confirm that this is a valid $PGDATA directory. --delta and --force have been disabled and if any files exist in the destination directories the restore will be aborted.
2026-01-16 18:44:25.776 P00   INFO: repo1: restore backup set 20260116-145747F, recovery will start at 2026-01-16 14:57:47
2026-01-16 18:44:30.740 P00   INFO: write updated /dbdata/pgsql/17/data/postgresql.auto.conf
2026-01-16 18:44:30.747 P00   INFO: restore global/pg_control (performed last to ensure aborted restores cannot be started)
2026-01-16 18:44:30.748 P00   INFO: restore size = 47.7MB, file total = 1285
2026-01-16 18:44:30.748 P00   INFO: restore command end: completed successfully (5115ms)
Restore completed successfully
Configuring standby settings...
Database restore and configuration completed
[2026-01-16 18:44:30] ✅ Command executed successfully on 10.41.241.171
[2026-01-16 18:44:30] ℹ️  INFO: State saved: DATABASE_RESTORED=true
[2026-01-16 18:44:30] ℹ️  INFO: State saved: RESTORE_SOURCE=s3
[2026-01-16 18:44:30] ℹ️  INFO: State saved: RECOVERY_TARGET=latest
[2026-01-16 18:44:30] ✅ Database restore completed
```

#### Step 7: Replication Slot Setup

```
[2026-01-16 18:44:30] === STEP 7: Setting up replication slot on primary ===
[2026-01-16 18:44:30] Executing on 10.41.241.74: Setting up replication slot
Replication slot standby3_slot already exists
pg_hba.conf already contains entries for 10.41.241.171
 pg_reload_conf
----------------
 t
(1 row)

   slot_name   | slot_type | active
---------------+-----------+--------
 standby3_slot | physical  | f
(1 row)

 application_name |  client_addr  |   state
------------------+---------------+-----------
 standby          | 10.41.241.191 | streaming
(1 row)

[2026-01-16 18:44:31] ✅ Command executed successfully on 10.41.241.74
[2026-01-16 18:44:31] ℹ️  INFO: State saved: REPLICATION_SLOT_CREATED=true
[2026-01-16 18:44:31] ✅ Replication slot setup completed
```

#### Step 8: Configuring and Starting Standby

```
[2026-01-16 18:44:31] === STEP 8: Configuring and starting new standby server ===
[2026-01-16 18:44:31] Executing on 10.41.241.171: service:
Checking for repmgr installation...
repmgr not found - PostgreSQL will work without cluster management
Detecting PostgreSQL service name...
Found
[2026-01-16 18:44:31] ✅ Command executed successfully on 10.41.241.171
[2026-01-16 18:44:31] ℹ️  INFO: State saved: STANDBY_CONFIGURED=true
[2026-01-16 18:44:31] ✅ New standby server configuration completed
```

#### Step 9: Testing Connections and Registration

```
[2026-01-16 18:44:31] === STEP 9: Registering with repmgr and final verification ===
[2026-01-16 18:44:31] Executing on 10.41.241.171: Testing connections
Testing connections...
 ?column?
----------
        1
(1 row)

Regular connection to primary: SUCCESS
      systemid       | timeline |  xlogpos  | dbname
---------------------+----------+-----------+--------
 7594773835055730102 |        1 | 0/F000168 |
(1 row)

Replication connection to primary: SUCCESS
[2026-01-16 18:44:32] ✅ Command executed successfully on 10.41.241.171
[2026-01-16 18:44:32] Executing on 10.41.241.171: Registering with repmgr
repmgr not found - skipping cluster registration
PostgreSQL replication is working without repmgr cluster management
[2026-01-16 18:44:32] ✅ Command executed successfully on 10.41.241.171
[2026-01-16 18:44:32] ℹ️  INFO: State saved: REPMGR_REGISTERED=true
[2026-01-16 18:44:32] ✅ repmgr registration completed
```

#### Step 10: Final Verification

```
[2026-01-16 18:44:32] === STEP 10: Final verification and testing ===
[2026-01-16 18:44:32] Executing on 10.41.241.74: Checking primary status and testing replication
=== Primary Replication Status ===
 application_name |  client_addr  |   state   | sync_state
------------------+---------------+-----------+------------
 standby          | 10.41.241.191 | streaming | async
(1 row)

=== Replication Slots ===
   slot_name   | active | active_pid
---------------+--------+------------
 standby_slot  | t      |     359466
 standby3_slot | f      |
(2 rows)

=== Testing Replication ===
CREATE TABLE
INSERT 0 1
[2026-01-16 18:44:32] ✅ Command executed successfully on 10.41.241.74

[2026-01-16 18:44:48] Executing on 10.41.241.171: Verifying replication on standby
=== Backup Verification ===
stanza: pg17_cluster
    status: ok
    cipher: none

    db (current)
        wal archive min/max (17): 00000001000000000000000B/00000001000000000000000E

        full backup: 20260116-145747F
            timestamp start/stop: 2026-01-16 14:57:47+00 / 2026-01-16 14:57:54+00
            wal start/stop: 00000001000000000000000E / 00000001000000000000000E
            database size: 47.7MB, database backup size: 47.7MB
            repo1: backup set size: 4.1MB, backup size: 4.1MB
[2026-01-16 18:44:48] ✅ Command executed successfully on 10.41.241.171
```

#### Deployment Summary

```
[2026-01-16 18:44:48] ℹ️  INFO: State saved: VERIFICATION_COMPLETED=true
[2026-01-16 18:44:48] ℹ️  INFO: State saved: SETUP_COMPLETED=2026-01-16 18:44:48
[2026-01-16 18:44:48] ✅ Final verification completed
[2026-01-16 18:44:48] === STANDBY SETUP COMPLETED SUCCESSFULLY! ===

[2026-01-16 18:44:48] ℹ️  INFO: === DEPLOYMENT SUMMARY ===
[2026-01-16 18:44:48] ℹ️  INFO: Primary Server: 10.41.241.74
[2026-01-16 18:44:48] ℹ️  INFO: Existing Standby: 10.41.241.191
[2026-01-16 18:44:48] ℹ️  INFO: New Standby: 10.41.241.171
[2026-01-16 18:44:48] ℹ️  INFO: PostgreSQL Version: 17
[2026-01-16 18:44:48] ℹ️  INFO: Stanza Name: pg17_cluster

[2026-01-16 18:44:48] ℹ️  INFO: === CLUSTER STRUCTURE ===
[2026-01-16 18:44:48] ℹ️  INFO: Node 1 (10.41.241.74) = Primary
[2026-01-16 18:44:48] ℹ️  INFO: Node 2 (10.41.241.191) = Existing Standby
[2026-01-16 18:44:48] ℹ️  INFO: Node 3 (10.41.241.171) = New Standby

[2026-01-16 18:44:48] ℹ️  INFO: === STATE FILE ===
[2026-01-16 18:44:48] ℹ️  INFO: Configuration saved to: /tmp/pgbackrest_standby_state.env
[2026-01-16 18:44:48] ℹ️  INFO: Current state:
[2026-01-16 18:44:48] ℹ️  INFO:   PGBACKREST_INSTALLED=true
[2026-01-16 18:44:48] ℹ️  INFO:   PGBACKREST_CONFIGURED=true
[2026-01-16 18:44:48] ℹ️  INFO:   DATABASE_RESTORED=true
[2026-01-16 18:44:48] ℹ️  INFO:   RESTORE_SOURCE=s3
[2026-01-16 18:44:48] ℹ️  INFO:   RECOVERY_TARGET=latest
[2026-01-16 18:44:48] ℹ️  INFO:   REPLICATION_SLOT_CREATED=true
[2026-01-16 18:44:48] ℹ️  INFO:   STANDBY_CONFIGURED=true
[2026-01-16 18:44:48] ℹ️  INFO:   REPMGR_REGISTERED=true
[2026-01-16 18:44:48] ℹ️  INFO:   VERIFICATION_COMPLETED=true
[2026-01-16 18:44:48] ℹ️  INFO:   SETUP_COMPLETED="2026-01-16 18:44:48"
```

#### Monitoring Commands

```bash
# Check replication status:
sudo -u postgres repmgr cluster show

# Check PostgreSQL logs:
tail -f /dbdata/pgsql/17/data/log/postgresql-*.log

# Check pgBackRest status:
sudo -u postgres pgbackrest --stanza=pg17_cluster info

# Test backup from new standby:
sudo -u postgres pgbackrest --stanza=pg17_cluster --type=full backup
```

#### Failover Commands

```bash
# Promote standby to primary:
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby promote

# Rejoin old primary as standby:
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf node rejoin -d 'host=NEW_PRIMARY_IP user=repmgr dbname=repmgr' --force-rewind
```

#### Key Metrics from S3 Restore

| Metric | Value |
|--------|-------|
| Restore Duration | ~5 seconds (5115ms) |
| Database Size | 47.7MB |
| Files Restored | 1,285 |
| Backup Set Size in S3 | 4.1MB (compressed) |
| Backup Used | 20260116-145747F |
| WAL Archive Range | 00000001000000000000000B to 00000001000000000000000E |

---

**End of Document**
