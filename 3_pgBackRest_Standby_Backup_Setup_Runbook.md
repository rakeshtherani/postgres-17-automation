# pgBackRest Standby Backup Setup Runbook
## PostgreSQL 17 Backup Configuration with EBS/S3 Support

---

## Document Information

| Field | Value |
|-------|-------|
| Document Version | 2.0 |
| Last Updated | 2026-01-16 |
| PostgreSQL Version | 17.x |
| pgBackRest Version | 2.55.1 |
| Target OS | Amazon Linux 2023 |
| Script Name | 4_pgbackrest_standby_backup_setup.sh |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Prerequisites and Requirements](#3-prerequisites-and-requirements)
4. [Pre-Deployment Checklist](#4-pre-deployment-checklist)
5. [EBS Storage Mode](#5-ebs-storage-mode)
6. [S3 Storage Mode](#6-s3-storage-mode)
7. [Dual Storage Mode (EBS + S3)](#7-dual-storage-mode-ebs--s3)
8. [Monitoring and Verification](#8-monitoring-and-verification)
9. [Backup Scheduling](#9-backup-scheduling)
10. [Operations Procedures](#10-operations-procedures)
11. [Troubleshooting Guide](#11-troubleshooting-guide)
12. [Appendix](#12-appendix)

---

## 1. Executive Summary

### Purpose
This runbook provides step-by-step instructions for setting up pgBackRest backups on a PostgreSQL 17 STANDBY server. Taking backups from the standby reduces load on the primary server.

### Scope
- Configure pgBackRest on standby server for backups
- Configure PRIMARY server for WAL archiving (EBS or S3)
- Support for EBS, S3, or both storage types
- Automatic EBS volume creation and snapshot management
- Scheduled backup configuration with cron

### Key Benefits

| Benefit | Description |
|---------|-------------|
| Reduced Primary Load | Backups run on standby, not primary |
| Multiple Storage Options | EBS for fast recovery, S3 for durability |
| Automated Configuration | Script configures BOTH primary and standby |
| PITR Support | Point-in-Time Recovery capability |
| Compression | ZST compression (typically 10:1 ratio) |

### What Gets Configured

| Server | EBS Mode | S3 Mode |
|--------|----------|---------|
| **PRIMARY** | pgBackRest config pointing to standby EBS | pgBackRest config pointing to S3 |
| **PRIMARY** | archive_command via SSH to standby | archive_command directly to S3 |
| **STANDBY** | pgBackRest config for local EBS backup | pgBackRest config for S3 backup |
| **STANDBY** | Base backups to local EBS | Base backups to S3 |

---

## 2. Architecture Overview

### 2.1 EBS Storage Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     EBS Storage Mode Architecture                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│    ┌──────────────────────┐              ┌──────────────────────┐           │
│    │      PRIMARY         │              │       STANDBY        │           │
│    │   10.41.241.74       │   Streaming  │   10.41.241.191      │           │
│    │                      │  Replication │   (Backup Server)    │           │
│    │  ┌────────────────┐  │ ──────────── │                      │           │
│    │  │ PostgreSQL 17  │  │              │  ┌────────────────┐  │           │
│    │  │ (Read/Write)   │  │              │  │ PostgreSQL 17  │  │           │
│    │  └────────────────┘  │              │  │ (Read Only)    │  │           │
│    │                      │              │  └────────────────┘  │           │
│    │  ┌────────────────┐  │   SSH/WAL    │                      │           │
│    │  │ pgBackRest     │  │ ──────────── │  ┌────────────────┐  │           │
│    │  │ archive-push   │  │  to standby  │  │ pgBackRest     │  │           │
│    │  │ (via SSH)      │  │              │  │ backup engine  │  │           │
│    │  └────────────────┘  │              │  └───────┬────────┘  │           │
│    │                      │              │          │           │           │
│    └──────────────────────┘              │          ▼           │           │
│                                          │  ┌────────────────┐  │           │
│                                          │  │ EBS Volume     │──┼──► Snapshot
│                                          │  │ /backup/       │  │           │
│                                          │  │ pgbackrest     │  │           │
│                                          │  │ (200GB gp3)    │  │           │
│                                          │  └────────────────┘  │           │
│                                          │                      │           │
│                                          └──────────────────────┘           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

Data Flow:
1. PRIMARY archives WAL → SSH → STANDBY EBS volume
2. STANDBY takes base backup → local EBS volume
3. EBS snapshot created for quick standby provisioning
```

### 2.2 S3 Storage Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      S3 Storage Mode Architecture                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│    ┌──────────────────────┐              ┌──────────────────────┐           │
│    │      PRIMARY         │              │       STANDBY        │           │
│    │   10.41.241.74       │   Streaming  │   10.41.241.191      │           │
│    │                      │  Replication │   (Backup Server)    │           │
│    │  ┌────────────────┐  │ ──────────── │                      │           │
│    │  │ PostgreSQL 17  │  │              │  ┌────────────────┐  │           │
│    │  │ (Read/Write)   │  │              │  │ PostgreSQL 17  │  │           │
│    │  └────────────────┘  │              │  │ (Read Only)    │  │           │
│    │                      │              │  └────────────────┘  │           │
│    │  ┌────────────────┐  │              │                      │           │
│    │  │ pgBackRest     │  │              │  ┌────────────────┐  │           │
│    │  │ archive-push   │──┼──────────────┼──│ pgBackRest     │  │           │
│    │  │ (direct to S3) │  │              │  │ backup engine  │  │           │
│    │  └───────┬────────┘  │              │  └───────┬────────┘  │           │
│    │          │           │              │          │           │           │
│    └──────────┼───────────┘              └──────────┼───────────┘           │
│               │                                     │                        │
│               │         ┌─────────────────┐         │                        │
│               │         │   S3 BUCKET     │         │                        │
│               └────────►│                 │◄────────┘                        │
│                WAL      │ btse-stg-       │    Base Backup                   │
│              Archive    │ pgbackrest-     │                                  │
│                         │ backup          │                                  │
│                         │                 │                                  │
│                         │ /pgbackrest/    │                                  │
│                         │  pg17_cluster/  │                                  │
│                         │   ├─ archive/   │ ◄── WAL files from PRIMARY       │
│                         │   └─ backup/    │ ◄── Base backups from STANDBY    │
│                         │                 │                                  │
│                         └─────────────────┘                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

Data Flow:
1. PRIMARY archives WAL → directly to S3 (using IAM role)
2. STANDBY takes base backup → directly to S3 (using IAM role)
3. All backup data stored durably in S3
```

### 2.3 Server Details

| Attribute | Primary | Standby (Backup Server) |
|-----------|---------|-------------------------|
| Hostname | tyo-aws-stg-binary-option-db-0001 | tyo-aws-stg-binary-option-db-0002 |
| IP Address | 10.41.241.74 | 10.41.241.191 |
| AWS Instance ID | i-052b680cf24be321e | i-013fe40421853b6b0 |
| Role | Read/Write + WAL Archive | Hot Standby + Backup Engine |

### 2.4 Storage Locations Summary

#### EBS Mode Storage Locations

| Data Type | Location | Server | Description |
|-----------|----------|--------|-------------|
| **WAL Files** | `/backup/pgbackrest/archive/` | STANDBY | Archived from PRIMARY via SSH |
| **Base Backups** | `/backup/pgbackrest/repo/` | STANDBY | Full and incremental backups |
| **Logs** | `/backup/pgbackrest/logs/` | STANDBY | pgBackRest operation logs |

```
STANDBY Server (10.41.241.191)
└── /backup/pgbackrest/           ← EBS Volume (200GB gp3)
    ├── repo/                     ← Base backups (full + incremental)
    │   └── pg17_cluster/
    │       ├── backup/           ← Database backup files
    │       │   └── pg17_cluster/
    │       │       ├── 20260116-xxxxF/   ← Full backup
    │       │       └── 20260116-xxxxI/   ← Incremental backup
    │       └── archive/          ← WAL files (archived from PRIMARY)
    │           └── pg17_cluster/
    │               └── 17-1/
    │                   └── 0000000100000000/
    │                       └── *.zst     ← Compressed WAL files
    └── logs/                     ← pgBackRest logs
```

**WAL Flow (EBS):** PRIMARY → SSH → STANDBY EBS Volume

#### S3 Mode Storage Locations

| Data Type | Location | Archived By | Description |
|-----------|----------|-------------|-------------|
| **WAL Files** | `s3://bucket/pgbackrest/stanza/archive/` | PRIMARY | Direct archive to S3 |
| **Base Backups** | `s3://bucket/pgbackrest/stanza/backup/` | STANDBY | Direct backup to S3 |

```
S3 Bucket (btse-stg-pgbackrest-backup)
└── pgbackrest/
    └── pg17_cluster/
        ├── backup/               ← Base backups from STANDBY
        │   └── pg17_cluster/
        │       ├── 20260116-145747F/     ← Full backup
        │       └── 20260116-xxxxxxI/     ← Incremental backups
        └── archive/              ← WAL files from PRIMARY
            └── pg17_cluster/
                └── 17-1/
                    └── 0000000100000000/
                        ├── 00000001000000000000000B-xxx.zst
                        ├── 00000001000000000000000C-xxx.zst
                        └── ...
```

**WAL Flow (S3):** PRIMARY → Direct → S3 Bucket
**Backup Flow (S3):** STANDBY → Direct → S3 Bucket

#### Storage Comparison Table

| Aspect | EBS Mode | S3 Mode |
|--------|----------|---------|
| **WAL archived by** | PRIMARY (via SSH to STANDBY) | PRIMARY (direct to S3) |
| **Base backup by** | STANDBY (to local EBS) | STANDBY (to S3) |
| **WAL location** | `/backup/pgbackrest/archive/` on STANDBY | `s3://bucket/pgbackrest/stanza/archive/` |
| **Backup location** | `/backup/pgbackrest/repo/` on STANDBY | `s3://bucket/pgbackrest/stanza/backup/` |
| **Recovery speed** | Fast (local disk) | Slower (network transfer) |
| **Durability** | EBS snapshots (99.999%) | S3 (99.999999999%) |
| **Cost** | EBS volume + snapshots | S3 storage only |
| **Cross-region DR** | Manual snapshot copy | S3 replication rules |

---

## 3. Prerequisites and Requirements

### 3.1 Hardware Requirements

| Resource | EBS Mode | S3 Mode | Notes |
|----------|----------|---------|-------|
| EBS Volume | 200 GB gp3 | Not required | For backup storage |
| Network | 1 Gbps | 10 Gbps recommended | S3 transfers need bandwidth |
| Memory | 4 GB | 4 GB | pgBackRest processes |

### 3.2 Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| PostgreSQL | 17.x | Database server |
| pgBackRest | 2.55.1 | Backup management |
| AWS CLI | 2.x | EBS/S3 operations |
| OpenSSL | 1.1+ | Compression libraries |

### 3.3 IAM Role Requirements

**Both PRIMARY and STANDBY need IAM roles with these permissions:**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3BackupAccess",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": "arn:aws:s3:::btse-stg-pgbackrest-backup"
        },
        {
            "Sid": "S3BackupObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::btse-stg-pgbackrest-backup/*"
        },
        {
            "Sid": "EBSSnapshotAccess",
            "Effect": "Allow",
            "Action": [
                "ec2:CreateVolume",
                "ec2:AttachVolume",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot",
                "ec2:DescribeVolumes",
                "ec2:DescribeSnapshots",
                "ec2:CreateTags"
            ],
            "Resource": "*"
        }
    ]
}
```

### 3.4 Network Requirements

| Port | Protocol | Source | Destination | Purpose |
|------|----------|--------|-------------|---------|
| 22 | TCP | Standby | Primary | SSH for pgBackRest (EBS mode) |
| 22 | TCP | Primary | Standby | SSH for pgBackRest (EBS mode) |
| 5432 | TCP | Standby | Primary | PostgreSQL connection |
| 443 | TCP | Both | AWS | S3 API access (S3 mode) |

---

## 4. Pre-Deployment Checklist

### 4.1 Server Preparation

- [ ] PostgreSQL 17 HA cluster is operational (repmgr configured)
- [ ] Standby server is in recovery mode (streaming replication working)
- [ ] Root SSH access available on standby
- [ ] Passwordless SSH configured: `standby (postgres) → primary (postgres)`

### 4.2 SSH Key Setup (Required for both modes)

```bash
# On STANDBY server as postgres user
sudo -u postgres ssh-keygen -t rsa -b 4096 -f /var/lib/pgsql/.ssh/id_rsa -N ""

# Copy public key to PRIMARY
sudo -u postgres ssh-copy-id -i /var/lib/pgsql/.ssh/id_rsa.pub postgres@10.41.241.74

# Test connectivity
sudo -u postgres ssh postgres@10.41.241.74 'hostname'
```

### 4.3 Verify IAM Role Access (S3 Mode)

```bash
# On BOTH servers - verify S3 access
aws s3 ls s3://btse-stg-pgbackrest-backup/

# Check IAM role
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

### 4.4 Verify Cluster Status

```bash
# On standby - verify it's in recovery mode
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Expected: t

# Verify replication is working
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf cluster show
```

---

## 5. EBS Storage Mode

### 5.1 Overview

EBS mode stores backups on a dedicated EBS volume attached to the standby server. EBS snapshots are created for quick standby provisioning.

**Pros:**
- Fast local backups and restores
- EBS snapshots for instant standby creation
- No network latency for backup operations

**Cons:**
- Limited to single AZ
- Requires dedicated EBS volume
- Higher cost for large datasets

### 5.2 Deployment Steps

```bash
# SSH to standby server
aws ssm start-session --target i-013fe40421853b6b0 --region ap-northeast-1

# Download script
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/4_pgbackrest_standby_backup_setup.sh /root/
chmod +x /root/4_pgbackrest_standby_backup_setup.sh

# Run with EBS storage
./4_pgbackrest_standby_backup_setup.sh --storage-type ebs
```

### 5.3 What Gets Configured (EBS Mode)

**On PRIMARY:**
```ini
# /etc/pgbackrest/pgbackrest.conf
[pg17_cluster]
pg1-path=/dbdata/pgsql/17/data

[global]
repo1-host=10.41.241.191        # Standby IP
repo1-host-user=postgres
repo1-path=/backup/pgbackrest/repo
```

**On STANDBY:**
```ini
# /etc/pgbackrest/pgbackrest.conf
[pg17_cluster]
pg1-path=/dbdata/pgsql/17/data
pg2-host=10.41.241.74           # Primary IP
pg2-path=/dbdata/pgsql/17/data
backup-standby=y

[global]
repo1-path=/backup/pgbackrest/repo
repo1-retention-full=4
repo1-retention-archive=14
```

### 5.4 Verify EBS Backup

```bash
# Check backup status
sudo -u postgres pgbackrest --stanza=pg17_cluster info

# List EBS snapshots
aws ec2 describe-snapshots \
    --owner-ids self \
    --filters "Name=tag:Stanza,Values=pg17_cluster" \
    --query 'Snapshots[*].[SnapshotId,StartTime,Description]' \
    --output table \
    --region ap-northeast-1
```

---

## 6. S3 Storage Mode

### 6.1 Overview

S3 mode stores backups directly in an S3 bucket. Both PRIMARY (WAL archive) and STANDBY (base backups) write directly to S3.

**Pros:**
- Unlimited storage capacity
- Cross-region disaster recovery possible
- Lower cost for long-term retention
- Durable (11 9's durability)

**Cons:**
- Depends on network bandwidth
- Slightly slower for large restores
- Requires IAM role on BOTH servers

### 6.2 Deployment Steps

```bash
# SSH to standby server
aws ssm start-session --target i-013fe40421853b6b0 --region ap-northeast-1

# Download script
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/4_pgbackrest_standby_backup_setup.sh /root/
chmod +x /root/4_pgbackrest_standby_backup_setup.sh

# Run with S3 storage
./4_pgbackrest_standby_backup_setup.sh --storage-type s3 --s3-bucket btse-stg-pgbackrest-backup
```

### 6.3 What Gets Configured (S3 Mode)

**On PRIMARY:**
```ini
# /etc/pgbackrest/pgbackrest.conf
[pg17_cluster]
pg1-path=/dbdata/pgsql/17/data
pg1-port=5432
pg1-socket-path=/tmp

[global]
repo1-type=s3
repo1-s3-bucket=btse-stg-pgbackrest-backup
repo1-s3-region=ap-northeast-1
repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com
repo1-s3-key-type=auto          # Uses IAM role
repo1-path=/pgbackrest/pg17_cluster
repo1-retention-full=4
repo1-retention-archive=14

log-level-console=info
log-path=/var/log/pgbackrest
```

**On STANDBY:**
```ini
# /etc/pgbackrest/pgbackrest.conf
[pg17_cluster]
pg1-path=/dbdata/pgsql/17/data
pg2-host=10.41.241.74
pg2-path=/dbdata/pgsql/17/data
backup-standby=y

[global]
repo1-type=s3
repo1-s3-bucket=btse-stg-pgbackrest-backup
repo1-s3-region=ap-northeast-1
repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com
repo1-s3-key-type=auto          # Uses IAM role
repo1-path=/pgbackrest/pg17_cluster
repo1-retention-full=4
repo1-retention-archive=14

log-level-console=info
log-path=/var/log/pgbackrest
```

### 6.4 S3 Bucket Structure

```
s3://btse-stg-pgbackrest-backup/
└── pgbackrest/
    └── pg17_cluster/
        ├── archive/
        │   └── pg17_cluster/
        │       ├── 17-1/
        │       │   └── 0000000100000000/
        │       │       ├── 00000001000000000000000B-xxx.zst
        │       │       ├── 00000001000000000000000C-xxx.zst
        │       │       ├── 00000001000000000000000D-xxx.zst
        │       │       └── 00000001000000000000000E-xxx.zst
        │       ├── archive.info
        │       └── archive.info.copy
        └── backup/
            └── pg17_cluster/
                ├── 20260116-145747F/           # Full backup
                │   ├── backup.manifest
                │   └── pg_data/
                ├── backup.info
                └── backup.info.copy
```

---

## 7. Dual Storage Mode (EBS + S3)

### 7.1 Overview

Dual mode uses both EBS and S3:
- **repo1 (EBS)**: Fast local recovery
- **repo2 (S3)**: Disaster recovery

### 7.2 Deployment Steps

```bash
./4_pgbackrest_standby_backup_setup.sh --storage-type both --s3-bucket btse-stg-pgbackrest-backup
```

### 7.3 Configuration (Dual Mode)

```ini
[global]
# Repository 1 - Local EBS (fast recovery)
repo1-path=/backup/pgbackrest/repo
repo1-retention-full=2

# Repository 2 - S3 (disaster recovery)
repo2-type=s3
repo2-s3-bucket=btse-stg-pgbackrest-backup
repo2-s3-key-type=auto
repo2-path=/pgbackrest/pg17_cluster
repo2-retention-full=4
```

---

## 8. Monitoring and Verification

### 8.1 Check Backup Status

```bash
# View all backups
sudo -u postgres pgbackrest --stanza=pg17_cluster info

# Example output:
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
```

### 8.2 Verify WAL Archiving to S3

```bash
# Check WAL files in S3
aws s3 ls s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster/archive/ --recursive

# Example output:
2026-01-16 14:57:43   700 pgbackrest/pg17_cluster/archive/pg17_cluster/17-1/0000000100000000/00000001000000000000000C-xxx.zst
2026-01-16 14:57:44   700 pgbackrest/pg17_cluster/archive/pg17_cluster/17-1/0000000100000000/00000001000000000000000D-xxx.zst
2026-01-16 14:57:45   700 pgbackrest/pg17_cluster/archive/pg17_cluster/17-1/0000000100000000/00000001000000000000000E-xxx.zst

# Count WAL files archived
aws s3 ls s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster/archive/ --recursive | wc -l

# Check archive status on PRIMARY
sudo -u postgres psql -c "SELECT * FROM pg_stat_archiver;"

# Force WAL switch and verify archive
sudo -u postgres psql -c "SELECT pg_switch_wal();"
sleep 5
aws s3 ls s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster/archive/ --recursive | tail -5
```

### 8.3 Verify Backup Files in S3

```bash
# List all backups in S3
aws s3 ls s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster/backup/ --recursive

# Check backup size
aws s3 ls s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster/backup/pg17_cluster/ --recursive --summarize

# Download and verify backup.info
aws s3 cp s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster/backup/pg17_cluster/backup.info -
```

### 8.4 Check PostgreSQL Archive Status

```bash
# On PRIMARY - check archive stats
sudo -u postgres psql -c "
SELECT
    archived_count,
    last_archived_wal,
    last_archived_time,
    failed_count,
    last_failed_wal,
    last_failed_time
FROM pg_stat_archiver;
"

# Check current WAL position
sudo -u postgres psql -c "SELECT pg_current_wal_lsn(), pg_walfile_name(pg_current_wal_lsn());"
```

### 8.5 Verify pgBackRest Check

```bash
# Run full check on standby
sudo -u postgres pgbackrest --stanza=pg17_cluster check

# Expected output:
# stanza: pg17_cluster
#     status: ok
```

### 8.6 Monitor Backup Logs

```bash
# View recent backup logs (S3 mode)
ls -la /var/log/pgbackrest/

# View recent backup logs (EBS mode)
ls -la /backup/pgbackrest/logs/

# Tail the latest log
tail -100 /var/log/pgbackrest/pg17_cluster-backup.log
```

---

## 9. Backup Scheduling

### 9.1 How Scheduled Backups Work

The initial script run creates `scheduled_standby_backup.sh` which:
- Automatically detects storage type (EBS or S3) from saved state
- Runs backups without user interaction
- Creates EBS snapshots (for EBS mode) after backup completes
- Logs all activity to `/var/log/pgbackrest_standby_scheduled_YYYYMMDD_HHMMSS.log`

**Backup Strategy:**
- **Sunday**: Full backup (complete database copy)
- **Monday-Saturday**: Incremental backup (changes since last backup)

### 9.2 Enable Cron Schedule

**Step 1: Set up cron for postgres user (recommended)**
```bash
# Switch to postgres user and add crontab
sudo -u postgres crontab -e

# Add this line for daily backups at 3 AM
0 3 * * * /root/scheduled_standby_backup.sh >> /var/log/pgbackrest_cron.log 2>&1
```

**Step 2: Or set up cron for root user**
```bash
# Edit root crontab
crontab -e

# Add this line
0 3 * * * /root/scheduled_standby_backup.sh >> /var/log/pgbackrest_cron.log 2>&1
```

**Step 3: Verify cron is set**
```bash
# Check crontab entries
crontab -l

# Check cron service is running
systemctl status crond
```

### 9.3 Schedule Options

| Schedule | Cron Expression | Use Case |
|----------|-----------------|----------|
| Daily at 3 AM | `0 3 * * *` | Standard production backup |
| Twice daily | `0 3,15 * * *` | High-change databases |
| Every 6 hours | `0 */6 * * *` | Critical systems |
| Weekly (Sunday 2 AM) | `0 2 * * 0` | Low-change databases |
| Hourly | `0 * * * *` | Very critical (high storage) |

### 9.4 What Happens During Scheduled Backup

**For EBS Mode:**
```
1. Script reads configuration from state file
2. Connects to PRIMARY to verify WAL archiving status
3. Takes incremental backup to /backup/pgbackrest/repo/
4. Creates EBS snapshot of backup volume
5. Cleans up old snapshots based on retention policy
6. Logs completion status
```

**For S3 Mode:**
```
1. Script reads configuration from state file
2. Verifies PRIMARY is archiving WAL to S3
3. Takes incremental backup directly to S3 bucket
4. pgBackRest handles retention automatically
5. Logs completion status
```

### 9.5 Manual Backup Commands

```bash
# Full backup (complete database copy)
sudo -u postgres pgbackrest --stanza=pg17_cluster --type=full backup

# Incremental backup (changes since last full/incr)
sudo -u postgres pgbackrest --stanza=pg17_cluster --type=incr backup

# Differential backup (changes since last full only)
sudo -u postgres pgbackrest --stanza=pg17_cluster --type=diff backup

# Force full backup via scheduled script
FORCE_FULL_BACKUP=true /root/scheduled_standby_backup.sh
```

### 9.6 Monitor Scheduled Backups

```bash
# Check last backup status
sudo -u postgres pgbackrest --stanza=pg17_cluster info

# View scheduled backup logs
ls -lt /var/log/pgbackrest_standby_scheduled_*.log | head -5

# Check latest log
tail -50 $(ls -t /var/log/pgbackrest_standby_scheduled_*.log | head -1)

# Check cron execution log
grep pgbackrest /var/log/cron

# Monitor backup size growth (S3)
aws s3 ls s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster/backup/ --recursive --summarize
```

---

## 10. Operations Procedures

### 10.1 Take Manual Backup

```bash
# Full backup to S3
sudo -u postgres pgbackrest --stanza=pg17_cluster --type=full backup

# Verify
sudo -u postgres pgbackrest --stanza=pg17_cluster info
```

### 10.2 Verify Backup Integrity

```bash
# Verify specific backup
sudo -u postgres pgbackrest --stanza=pg17_cluster --set=20260116-145747F verify

# Verify all backups
sudo -u postgres pgbackrest --stanza=pg17_cluster verify
```

### 10.3 Expire Old Backups

```bash
# pgBackRest handles retention automatically
# Manual expire (removes backups beyond retention)
sudo -u postgres pgbackrest --stanza=pg17_cluster expire
```

### 10.4 Restore from S3 Backup

```bash
# Stop PostgreSQL
sudo systemctl stop postgresql-17

# Restore latest backup
sudo -u postgres pgbackrest --stanza=pg17_cluster restore

# Or restore specific backup
sudo -u postgres pgbackrest --stanza=pg17_cluster --set=20260116-145747F restore

# Start PostgreSQL
sudo systemctl start postgresql-17
```

### 10.5 Point-in-Time Recovery (PITR)

```bash
# Restore to specific time
sudo -u postgres pgbackrest --stanza=pg17_cluster \
    --type=time \
    --target="2026-01-16 14:00:00" \
    --target-action=promote \
    restore
```

---

## 11. Troubleshooting Guide

### 11.1 WAL Not Archiving to S3

**Error:**
```
WAL segment was not archived before timeout
```

**Solution:**
```bash
# Check PRIMARY pgbackrest config
cat /etc/pgbackrest/pgbackrest.conf

# Verify S3 access from PRIMARY
aws s3 ls s3://btse-stg-pgbackrest-backup/

# Test manual archive-push from PRIMARY
sudo -u postgres pgbackrest --stanza=pg17_cluster archive-push \
    /dbdata/pgsql/17/data/pg_wal/000000010000000000000001 --log-level-console=info

# Check archive_command
sudo -u postgres psql -c "SHOW archive_command;"
```

### 11.2 S3 Access Denied

**Error:**
```
repo1-s3-key required
```

**Solution:**
```bash
# Verify pgbackrest.conf has IAM auth
grep "s3-key-type" /etc/pgbackrest/pgbackrest.conf
# Should show: repo1-s3-key-type=auto

# Check IAM role
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/

# Verify S3 access
aws s3 ls s3://btse-stg-pgbackrest-backup/
```

### 11.3 SSH Connection Failed (EBS Mode)

**Error:**
```
Cannot SSH to primary server as postgres user
```

**Solution:**
```bash
# Check SSH key exists
ls -la /var/lib/pgsql/.ssh/id_rsa

# Regenerate if needed
sudo -u postgres ssh-keygen -t rsa -b 4096 -f /var/lib/pgsql/.ssh/id_rsa -N ""

# Copy to primary
sudo -u postgres ssh-copy-id -i /var/lib/pgsql/.ssh/id_rsa.pub postgres@10.41.241.74

# Test connection
sudo -u postgres ssh postgres@10.41.241.74 'hostname'
```

### 11.4 Backup Failed - Stanza Issues

**Error:**
```
stanza 'pg17_cluster' does not exist
```

**Solution:**
```bash
# Recreate stanza
sudo -u postgres pgbackrest --stanza=pg17_cluster stanza-create

# Verify
sudo -u postgres pgbackrest --stanza=pg17_cluster check
```

---

## 12. Appendix

### 12.1 Quick Reference Commands

| Task | Command |
|------|---------|
| Check backup status | `sudo -u postgres pgbackrest --stanza=pg17_cluster info` |
| Take full backup | `sudo -u postgres pgbackrest --stanza=pg17_cluster --type=full backup` |
| Verify backup | `sudo -u postgres pgbackrest --stanza=pg17_cluster verify` |
| Check WAL in S3 | `aws s3 ls s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster/archive/ --recursive` |
| Check archive status | `sudo -u postgres psql -c "SELECT * FROM pg_stat_archiver;"` |
| Force WAL switch | `sudo -u postgres psql -c "SELECT pg_switch_wal();"` |
| Expire old backups | `sudo -u postgres pgbackrest --stanza=pg17_cluster expire` |

### 12.2 Configuration Files

| Server | File | Purpose |
|--------|------|---------|
| PRIMARY | `/etc/pgbackrest/pgbackrest.conf` | pgBackRest config (S3 or EBS) |
| PRIMARY | `/var/log/pgbackrest/` | pgBackRest logs |
| STANDBY | `/etc/pgbackrest/pgbackrest.conf` | pgBackRest config (S3 or EBS) |
| STANDBY | `/root/pgbackrest_standby_backup_state.env` | State file |
| STANDBY | `/root/scheduled_standby_backup.sh` | Scheduled backup script |

### 12.3 Script Location

```
S3: s3://btse-stg-pgbackrest-backup/scripts/4_pgbackrest_standby_backup_setup.sh
```

### 12.4 Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `PRIMARY_IP` | 10.41.241.74 | Primary server IP |
| `STANDBY_IP` | 10.41.241.191 | Standby server IP |
| `PG_VERSION` | 17 | PostgreSQL version |
| `STANZA_NAME` | pg17_cluster | pgBackRest stanza name |
| `AWS_REGION` | ap-northeast-1 | AWS region |
| `STORAGE_TYPE` | ebs | Storage type (ebs/s3/both) |
| `S3_BUCKET` | - | S3 bucket name |
| `BACKUP_MODE` | auto | Backup type selection |

---

## 13. Complete Execution Output Logs

This section contains complete output from successful script executions for reference.

### 13.1 EBS Storage Mode - Complete Output

```bash
[root@tyo-aws-stg-binary-option-db-0002 ~]# ./pgbackrest_standby_backup_setup.sh

===============================================================================
  pgBackRest Standby Backup Setup Script v3.0
  PostgreSQL 17 with S3/EBS Storage Support
===============================================================================

[2026-01-14 08:17:41] INFO: State loaded from: /root/pgbackrest_standby_backup_state.env
[2026-01-14 08:17:41] INFO: Configuration:
[2026-01-14 08:17:41] INFO:   Primary IP: 10.41.241.74
[2026-01-14 08:17:41] INFO:   Standby IP: 10.41.241.191 (this server)
[2026-01-14 08:17:41] INFO:   PostgreSQL Version: 17
[2026-01-14 08:17:41] INFO:   Data Directory: /dbdata/pgsql/17/data
[2026-01-14 08:17:41] INFO:   Stanza Name: pg17_cluster
[2026-01-14 08:17:41] INFO:   AWS Region: ap-northeast-1
[2026-01-14 08:17:41] INFO:   Backup Mode: auto
[2026-01-14 08:17:41] INFO:   Storage Type: ebs

Do you want to proceed with standby backup setup? (yes/no): yes

[2026-01-14 08:17:42] INFO: === BACKUP STORAGE TYPE SELECTION ===

Choose where to store your backups:

  1) EBS (Local EBS Volume)
     - Fast local backups with EBS snapshots
     - Good for quick standby provisioning
     - Requires additional EBS volume

  2) S3 (AWS S3 Bucket)
     - Durable, unlimited storage
     - Lower cost for long-term retention
     - Requires S3 bucket and IAM permissions

  3) Both (EBS + S3)
     - Local EBS for fast recovery
     - S3 for disaster recovery
     - Best protection, higher cost

Select storage type [1/2/3] (default: 1): 1
[2026-01-14 08:17:43] INFO: Selected: EBS storage
[2026-01-14 08:17:43] INFO: State saved: STORAGE_TYPE=ebs
[2026-01-14 08:17:43] Checking prerequisites for standby backup setup...
[2026-01-14 08:17:43] INFO: Verifying server IP configuration...
[2026-01-14 08:17:43] INFO: Current server IP: 10.41.241.191
[2026-01-14 08:17:43] INFO: Expected standby IP: 10.41.241.191
[2026-01-14 08:17:43] Server IP verified: running on correct standby server (10.41.241.191)
[2026-01-14 08:17:43] INFO: Verifying this server is a standby in the repmgr cluster...
[2026-01-14 08:17:44] INFO: Checking SSH connectivity to primary server...
[2026-01-14 08:17:44] Prerequisites check completed - server confirmed as standby

[2026-01-14 08:17:44] === STEP 1: Setting up backup volume on standby ===
[2026-01-14 08:17:44] INFO: No backup mount point found - checking for available devices
[2026-01-14 08:17:44] WARNING: No dedicated backup device found
[2026-01-14 08:17:44] INFO: AWS credentials available - creating EBS volume for backups
[2026-01-14 08:17:44] INFO: Creating 200GB EBS volume in ap-northeast-1a...
[2026-01-14 08:17:45] Created volume: vol-0ec0b70e6682ed5cf
{
    "VolumeId": "vol-0ec0b70e6682ed5cf",
    "InstanceId": "i-013fe40421853b6b0",
    "Device": "/dev/xvdb",
    "State": "attaching",
    "AttachTime": "2026-01-14T08:18:02.813000+00:00"
}
[2026-01-14 08:18:03] INFO: Waiting for volume to attach...
[2026-01-14 08:18:04] Device available at: /dev/xvdb
mke2fs 1.46.5 (30-Dec-2021)
Creating filesystem with 52428800 4k blocks and 13107200 inodes
Filesystem UUID: aaa27c62-9828-4ac0-9a9c-4e5368bbf400
Superblock backups stored on blocks:
    32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208,
    4096000, 7962624, 11239424, 20480000, 23887872

Allocating group tables: done
Writing inode tables: done
Creating journal (262144 blocks): done
Writing superblocks and filesystem accounting information: done

UUID=aaa27c62-9828-4ac0-9a9c-4e5368bbf400 /backup/pgbackrest ext4 defaults,nofail 0 2
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme2n1    196G   40K  186G   1% /backup/pgbackrest
total 32
drwxr-x---. 6 postgres postgres  4096 Jan 14 08:18 .
drwxr-xr-x. 3 root     root        24 Jan 14 08:18 ..
drwxr-xr-x. 2 postgres postgres  4096 Jan 14 08:18 archive
drwxr-xr-x. 2 postgres postgres  4096 Jan 14 08:18 logs
drwx------. 2 postgres postgres 16384 Jan 14 08:18 lost+found
drwxr-xr-x. 2 postgres postgres  4096 Jan 14 08:18 repo
[2026-01-14 08:18:11] INFO: State saved: BACKUP_VOLUME_CONFIGURED=true
[2026-01-14 08:18:11] Backup volume setup completed

[2026-01-14 08:18:11] === STEP 2: Configuring pgBackRest on standby ===
[2026-01-14 08:18:11] INFO: pgBackRest already installed
pgBackRest 2.55.1
[2026-01-14 08:18:11] INFO: Configuring primary server for multi-repository setup...
[2026-01-14 08:18:11] INFO: This standby already configured as repo1 on primary
[2026-01-14 08:18:11] INFO: State saved: STANDBY_REPO_NUMBER=1
[2026-01-14 08:18:11] INFO: Checking archive_mode on primary...
[2026-01-14 08:18:11] INFO: archive_mode already enabled on primary
[2026-01-14 08:18:12] INFO: Using repo path from primary: /backup/pgbackrest/repo
[2026-01-14 08:18:12] INFO: Creating pgBackRest configuration for standby backup (storage: ebs)...

[pg17_cluster]
# Local standby server
pg1-path=/dbdata/pgsql/17/data
pg1-port=5432
pg1-socket-path=/tmp

# Primary server (required for standby backups)
pg2-host=10.41.241.74
pg2-path=/dbdata/pgsql/17/data
pg2-port=5432
pg2-host-user=postgres
pg2-socket-path=/tmp

# Standby-specific settings
backup-standby=y
delta=y

[global]
# Repository 1 - Local EBS storage
repo1-path=/backup/pgbackrest/repo
repo1-retention-full=4
repo1-retention-diff=7
repo1-retention-archive=14

process-max=8
start-fast=y
stop-auto=y
compress-type=zst
compress-level=3
log-level-console=info
log-level-file=detail
log-path=/backup/pgbackrest/logs

# Archive settings
archive-get-queue-max=128MB
archive-push-queue-max=128MB

[2026-01-14 08:18:12] INFO: State saved: PGBACKREST_CONFIGURED=true
[2026-01-14 08:18:12] INFO: State saved: STORAGE_TYPE=ebs
[2026-01-14 08:18:12] pgBackRest configuration completed (storage: ebs)
[2026-01-14 08:18:12] WARNING: No recent full backup found, taking full backup instead of incremental

[2026-01-14 08:18:12] === STEP 3: Creating stanza and taking full backup from standby ===
[2026-01-14 08:18:12] INFO: Using repo path from primary: /backup/pgbackrest/repo
[2026-01-14 08:18:12] INFO: Creating pgBackRest stanza for repo1...
2026-01-14 08:18:12.727 P00   INFO: stanza-create command begin 2.55.1: --exec-id=188460-dbf2efdb --log-level-console=info --log-level-file=detail --log-path=/backup/pgbackrest/logs --pg2-host=10.41.241.74 --pg2-host-user=postgres --pg1-path=/dbdata/pgsql/17/data --pg2-path=/dbdata/pgsql/17/data --pg1-port=5432 --pg2-port=5432 --pg1-socket-path=/tmp --pg2-socket-path=/tmp --repo1-path=/backup/pgbackrest/repo --stanza=pg17_cluster
2026-01-14 08:18:12.961 P00   INFO: stanza-create for stanza 'pg17_cluster' on repo1
2026-01-14 08:18:13.073 P00   INFO: stanza-create command end: completed successfully (347ms)
[2026-01-14 08:18:13] INFO: Using repo path from primary: /backup/pgbackrest/repo
[2026-01-14 08:18:13] INFO: Taking full backup from standby server (repo1 on primary)...
[2026-01-14 08:18:13] WARNING: Note: Standby backups may take longer than primary backups
2026-01-14 08:18:13.280 P00   INFO: backup command begin 2.55.1: --backup-standby=y --compress-level=3 --compress-type=zst --delta --exec-id=188478-a38594bd --log-level-console=info --log-level-file=detail --log-path=/backup/pgbackrest/logs --pg2-host=10.41.241.74 --pg2-host-user=postgres --pg1-path=/dbdata/pgsql/17/data --pg2-path=/dbdata/pgsql/17/data --pg1-port=5432 --pg2-port=5432 --pg1-socket-path=/tmp --pg2-socket-path=/tmp --process-max=8 --repo1-path=/backup/pgbackrest/repo --repo1-retention-archive=14 --repo1-retention-diff=7 --repo1-retention-full=4 --stanza=pg17_cluster --start-fast --stop-auto --type=full
2026-01-14 08:18:13.502 P00   INFO: execute non-exclusive backup start: backup begins after the requested immediate checkpoint completes
2026-01-14 08:18:13.569 P00   INFO: backup start archive = 000000010000000000000006, lsn = 0/6000028
2026-01-14 08:18:13.570 P00   INFO: wait for replay on the standby to reach 0/6000028
2026-01-14 08:18:13.682 P00   INFO: replay on the standby reached 0/6000028
2026-01-14 08:18:13.682 P00   INFO: check archive for prior segment 000000010000000000000005
2026-01-14 08:18:17.137 P00   INFO: execute non-exclusive backup stop and wait for all WAL segments to archive
2026-01-14 08:18:17.166 P00   INFO: backup stop archive = 000000010000000000000006, lsn = 0/6000120
2026-01-14 08:18:17.174 P00   INFO: check archive for segment(s) 000000010000000000000006:000000010000000000000006
2026-01-14 08:18:17.587 P00   INFO: new backup label = 20260114-081813F
2026-01-14 08:18:17.644 P00   INFO: full backup size = 30.5MB, file total = 1283
2026-01-14 08:18:17.644 P00   INFO: backup command end: completed successfully (4366ms)
2026-01-14 08:18:17.645 P00   INFO: expire command begin 2.55.1: --exec-id=188478-a38594bd --log-level-console=info --log-level-file=detail --log-path=/backup/pgbackrest/logs --repo1-path=/backup/pgbackrest/repo --repo1-retention-archive=14 --repo1-retention-diff=7 --repo1-retention-full=4 --stanza=pg17_cluster
2026-01-14 08:18:17.645 P00   INFO: expire command end: completed successfully (1ms)
[2026-01-14 08:18:17] full backup completed from standby
[2026-01-14 08:18:17] INFO: Verifying backup...

stanza: pg17_cluster
    status: ok
    cipher: none

    db (current)
        wal archive min/max (17): 000000010000000000000005/000000010000000000000006

        full backup: 20260114-081813F
            timestamp start/stop: 2026-01-14 08:18:13+00 / 2026-01-14 08:18:17+00
            wal start/stop: 000000010000000000000006 / 000000010000000000000006
            database size: 30.5MB, database backup size: 30.5MB
            repo1: backup set size: 3.7MB, backup size: 3.7MB

[2026-01-14 08:18:17] INFO: State saved: INITIAL_BACKUP_COMPLETED=true
[2026-01-14 08:18:17] INFO: State saved: LAST_BACKUP_TYPE=full
[2026-01-14 08:18:17] INFO: State saved: LAST_BACKUP_DATE="2026-01-14 08:18:17"
[2026-01-14 08:18:17] INFO: State saved: BACKUP_FROM_STANDBY=true
[2026-01-14 08:18:17] INFO: State saved: STANZA_NAME=pg17_cluster

[2026-01-14 08:18:17] === STEP 4: Creating EBS snapshot of standby backup volume ===
[2026-01-14 08:18:17] INFO: Instance ID: i-013fe40421853b6b0
[2026-01-14 08:18:18] INFO: Direct device lookup failed for /dev/nvme2n1, trying alternative mappings...
[2026-01-14 08:18:18] INFO: Trying AWS device mapping: /dev/xvdb
[2026-01-14 08:18:19] INFO: Found backup volume using alternative device mapping: /dev/xvdb -> vol-0ec0b70e6682ed5cf
[2026-01-14 08:18:19] INFO: Backup Volume ID: vol-0ec0b70e6682ed5cf
[2026-01-14 08:18:20] INFO: Snapshot created: snap-03327404502cd8b25
[2026-01-14 08:18:20] INFO: State saved: BACKUP_VOLUME_ID=vol-0ec0b70e6682ed5cf
[2026-01-14 08:18:20] INFO: State saved: LATEST_SNAPSHOT_ID=snap-03327404502cd8b25
[2026-01-14 08:18:20] INFO: State saved: LAST_SNAPSHOT_DATE="2026-01-14 08:18:20"
[2026-01-14 08:18:20] INFO: State saved: SNAPSHOT_AVAILABLE=true
[2026-01-14 08:18:20] Waiting for snapshot to complete...
[2026-01-14 08:19:51] Snapshot completed: snap-03327404502cd8b25

[2026-01-14 08:19:51] === Cleaning up old standby snapshots ===
[2026-01-14 08:19:52] INFO: No old snapshots to clean up

[2026-01-14 08:19:52] === Setting up periodic snapshots from standby ===
[2026-01-14 08:19:52] INFO: Scheduled backup script created: /root/scheduled_standby_backup.sh
[2026-01-14 08:19:52] INFO:
[2026-01-14 08:19:52] INFO: To enable automatic backups from standby, add to crontab:
[2026-01-14 08:19:52] INFO:   # Daily backup from standby at 3 AM (full on Sunday, incremental Mon-Sat)
[2026-01-14 08:19:52] INFO:   0 3 * * * /root/scheduled_standby_backup.sh
[2026-01-14 08:19:52] INFO: State saved: PERIODIC_SNAPSHOTS_CONFIGURED=true
[2026-01-14 08:19:52] Periodic snapshot setup completed

[2026-01-14 08:19:52] === STANDBY BACKUP SETUP COMPLETED SUCCESSFULLY! ===

[2026-01-14 08:19:52] INFO: === CONFIGURATION SUMMARY ===
[2026-01-14 08:19:52] INFO: Primary Server: 10.41.241.74
[2026-01-14 08:19:52] INFO: Standby Server: 10.41.241.191 (this server)
[2026-01-14 08:19:52] INFO: PostgreSQL Version: 17
[2026-01-14 08:19:52] INFO: Data Directory: /dbdata/pgsql/17/data
[2026-01-14 08:19:52] INFO: Stanza Name: pg17_cluster
[2026-01-14 08:19:52] INFO: Storage Type: ebs
[2026-01-14 08:19:52] INFO: EBS Backup Location: /backup/pgbackrest
[2026-01-14 08:19:52] INFO: Backup Volume: vol-0ec0b70e6682ed5cf
[2026-01-14 08:19:52] INFO: Latest Snapshot: snap-03327404502cd8b25

[2026-01-14 08:19:52] INFO: === REPMGR CLUSTER STATUS ===
 ID | Name    | Role    | Status    | Upstream | Location | Priority | Timeline | Connection string
----+---------+---------+-----------+----------+----------+----------+----------+----------------------------------------------------------------
 1  | primary | primary | * running |          | default  | 100      | 1        | host=10.41.241.74 user=repmgr dbname=repmgr connect_timeout=2
 2  | standby | standby |   running | primary  | default  | 100      | 1        | host=10.41.241.191 user=repmgr dbname=repmgr connect_timeout=2

[2026-01-14 08:19:52] INFO: === STATE FILE ===
[2026-01-14 08:19:52] INFO: Configuration saved to: /root/pgbackrest_standby_backup_state.env
[2026-01-14 08:19:52] INFO: This file is needed for pgbackrest_standby_setup.sh

[2026-01-14 08:19:52] INFO: === NEXT STEPS ===
[2026-01-14 08:19:52] INFO: 1. Use EBS snapshot to create new standbys:
[2026-01-14 08:19:52] INFO:    ./pgbackrest_standby_setup.sh --state-file /root/pgbackrest_standby_backup_state.env
[2026-01-14 08:19:52] INFO: 2. Enable scheduled backups (optional):
[2026-01-14 08:19:52] INFO:    echo '0 3 * * * /root/scheduled_standby_backup.sh' | crontab -
[2026-01-14 08:19:52] INFO: 3. Monitor backup status:
[2026-01-14 08:19:52] INFO:    sudo -u postgres pgbackrest --stanza=pg17_cluster info

[2026-01-14 08:19:52] INFO: === IMPORTANT NOTES ===
[2026-01-14 08:19:52] INFO: - Backups are taken from standby to reduce primary load
[2026-01-14 08:19:52] INFO: - Standby backups may take longer than primary backups
[2026-01-14 08:19:52] INFO: - EBS snapshots are tagged with 'Source=standby' for identification
[2026-01-14 08:19:52] INFO: - Snapshots can be used to quickly create new standby servers

[2026-01-14 08:19:52] Log saved to: /root/pgbackrest_standby_backup_20260114_081741.log
[2026-01-14 08:19:52] Execution completed successfully!
```

### 13.2 S3 Storage Mode - Complete Output

```bash
[root@tyo-aws-stg-binary-option-db-0002 ~]# ./pgbackrest_standby_backup_setup.sh --storage-type s3 --s3-bucket btse-stg-pgbackrest-backup

===============================================================================
  pgBackRest Standby Backup Setup Script v3.0
  PostgreSQL 17 with S3/EBS Storage Support
===============================================================================

[2026-01-16 14:57:35] INFO: No existing state file found
[2026-01-16 14:57:35] INFO: Configuration:
[2026-01-16 14:57:35] INFO:   Primary IP: 10.41.241.74
[2026-01-16 14:57:35] INFO:   Standby IP: 10.41.241.191 (this server)
[2026-01-16 14:57:35] INFO:   PostgreSQL Version: 17
[2026-01-16 14:57:35] INFO:   Data Directory: /dbdata/pgsql/17/data
[2026-01-16 14:57:35] INFO:   Stanza Name: pg17_cluster
[2026-01-16 14:57:35] INFO:   AWS Region: ap-northeast-1
[2026-01-16 14:57:35] INFO:   Backup Mode: auto
[2026-01-16 14:57:35] INFO:   Storage Type: s3
[2026-01-16 14:57:35] INFO:   S3 Bucket: btse-stg-pgbackrest-backup

Do you want to proceed with standby backup setup? (yes/no): yes
[2026-01-16 14:57:38] INFO: Validating S3 access...
[2026-01-16 14:57:39] S3 bucket access validated: btse-stg-pgbackrest-backup
[2026-01-16 14:57:39] Checking prerequisites for standby backup setup...
[2026-01-16 14:57:39] INFO: Verifying server IP configuration...
[2026-01-16 14:57:39] INFO: Current server IP: 10.41.241.191
[2026-01-16 14:57:39] INFO: Expected standby IP: 10.41.241.191
[2026-01-16 14:57:39] Server IP verified: running on correct standby server (10.41.241.191)
[2026-01-16 14:57:39] INFO: Verifying this server is a standby in the repmgr cluster...
[2026-01-16 14:57:39] INFO: Checking SSH connectivity to primary server...
[2026-01-16 14:57:40] Prerequisites check completed - server confirmed as standby

[2026-01-16 14:57:40] === STEP 2: Configuring pgBackRest on standby ===
[2026-01-16 14:57:40] INFO: pgBackRest already installed
pgBackRest 2.55.1
[2026-01-16 14:57:40] INFO: Configuring primary server for multi-repository setup...
[2026-01-16 14:57:40] INFO: Configuring PRIMARY server for S3 WAL archiving...
[2026-01-16 14:57:40] INFO: Checking S3 access from primary server...
[2026-01-16 14:57:40] PRIMARY server has S3 access
[2026-01-16 14:57:40] INFO: Creating pgBackRest S3 configuration on primary...
[2026-01-16 14:57:41] pgBackRest S3 configuration created on primary
[2026-01-16 14:57:41] INFO: Verifying pgBackRest S3 access from primary...
[2026-01-16 14:57:41] INFO: Testing WAL archiving to S3 from primary...
 pg_switch_wal
---------------
 0/C000148
(1 row)

[2026-01-16 14:57:45] WAL archiving to S3 is working from primary
[2026-01-16 14:57:45] INFO: Recent WAL files in S3:
2026-01-16 14:57:43    700 pgbackrest/pg17_cluster/archive/pg17_cluster/17-1/0000000100000000/00000001000000000000000C-7987ffff53e4faa26df47cab8ac474d729666d50.zst
2026-01-14 10:36:57    255 pgbackrest/pg17_cluster/archive/pg17_cluster/archive.info
2026-01-14 10:36:57    255 pgbackrest/pg17_cluster/archive/pg17_cluster/archive.info.copy
[2026-01-16 14:57:45] INFO: State saved: PRIMARY_S3_CONFIGURED=true
[2026-01-16 14:57:45] Primary server configured for S3 WAL archiving
[2026-01-16 14:57:45] INFO: State saved: STANDBY_REPO_NUMBER=1
[2026-01-16 14:57:45] INFO: Checking archive_mode on primary...
[2026-01-16 14:57:45] INFO: archive_mode already enabled on primary
[2026-01-16 14:57:46] INFO: Using repo path from primary: /pgbackrest/pg17_cluster
[2026-01-16 14:57:46] INFO: Creating pgBackRest configuration for standby backup (storage: s3)...

[pg17_cluster]
# Local standby server
pg1-path=/dbdata/pgsql/17/data
pg1-port=5432
pg1-socket-path=/tmp

# Primary server (required for standby backups)
pg2-host=10.41.241.74
pg2-path=/dbdata/pgsql/17/data
pg2-port=5432
pg2-host-user=postgres
pg2-socket-path=/tmp

# Standby-specific settings
backup-standby=y
delta=y

[global]
# Repository 1 - S3 storage
repo1-type=s3
repo1-s3-bucket=btse-stg-pgbackrest-backup
repo1-s3-region=ap-northeast-1
repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com
repo1-s3-key-type=auto
repo1-path=/pgbackrest/pg17_cluster
repo1-retention-full=4
repo1-retention-diff=7
repo1-retention-archive=14

process-max=8
start-fast=y
stop-auto=y
compress-type=zst
compress-level=3
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest

# Archive settings
archive-get-queue-max=128MB
archive-push-queue-max=128MB

[2026-01-16 14:57:46] INFO: State saved: PGBACKREST_CONFIGURED=true
[2026-01-16 14:57:46] INFO: State saved: STORAGE_TYPE=s3
[2026-01-16 14:57:46] pgBackRest configuration completed (storage: s3)
[2026-01-16 14:57:46] WARNING: No recent full backup found, taking full backup instead of incremental

[2026-01-16 14:57:46] === STEP 3: Creating stanza and taking full backup from standby ===
[2026-01-16 14:57:46] INFO: Using repo path from primary: /pgbackrest/pg17_cluster
[2026-01-16 14:57:46] INFO: Creating pgBackRest stanza for repo1...
2026-01-16 14:57:46.639 P00   INFO: stanza-create command begin 2.55.1: --exec-id=385542-97852d5a --log-level-console=info --log-level-file=detail --log-path=/var/log/pgbackrest --pg2-host=10.41.241.74 --pg2-host-user=postgres --pg1-path=/dbdata/pgsql/17/data --pg2-path=/dbdata/pgsql/17/data --pg1-port=5432 --pg2-port=5432 --pg1-socket-path=/tmp --pg2-socket-path=/tmp --repo1-path=/pgbackrest/pg17_cluster --repo1-s3-bucket=btse-stg-pgbackrest-backup --repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com --repo1-s3-key-type=auto --repo1-s3-region=ap-northeast-1 --repo1-type=s3 --stanza=pg17_cluster
2026-01-16 14:57:46.868 P00   INFO: stanza-create for stanza 'pg17_cluster' on repo1
2026-01-16 14:57:47.020 P00   INFO: stanza 'pg17_cluster' already exists on repo1 and is valid
2026-01-16 14:57:47.120 P00   INFO: stanza-create command end: completed successfully (483ms)
[2026-01-16 14:57:47] INFO: Using repo path from primary: /pgbackrest/pg17_cluster
[2026-01-16 14:57:47] INFO: Taking full backup from standby server (repo1 on primary)...
[2026-01-16 14:57:47] WARNING: Note: Standby backups may take longer than primary backups
2026-01-16 14:57:47.352 P00   INFO: backup command begin 2.55.1: --backup-standby=y --compress-level=3 --compress-type=zst --delta --exec-id=385560-0553f49c --log-level-console=info --log-level-file=detail --log-path=/var/log/pgbackrest --pg2-host=10.41.241.74 --pg2-host-user=postgres --pg1-path=/dbdata/pgsql/17/data --pg2-path=/dbdata/pgsql/17/data --pg1-port=5432 --pg2-port=5432 --pg1-socket-path=/tmp --pg2-socket-path=/tmp --process-max=8 --repo1-path=/pgbackrest/pg17_cluster --repo1-retention-archive=14 --repo1-retention-diff=7 --repo1-retention-full=4 --repo1-s3-bucket=btse-stg-pgbackrest-backup --repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com --repo1-s3-key-type=auto --repo1-s3-region=ap-northeast-1 --repo1-type=s3 --stanza=pg17_cluster --start-fast --stop-auto --type=full
2026-01-16 14:57:47.685 P00   INFO: execute non-exclusive backup start: backup begins after the requested immediate checkpoint completes
2026-01-16 14:57:47.754 P00   INFO: backup start archive = 00000001000000000000000E, lsn = 0/E000028
2026-01-16 14:57:47.754 P00   INFO: wait for replay on the standby to reach 0/E000028
2026-01-16 14:57:47.870 P00   INFO: replay on the standby reached 0/E000028
2026-01-16 14:57:47.870 P00   INFO: check archive for prior segment 00000001000000000000000D
2026-01-16 14:57:54.071 P00   INFO: execute non-exclusive backup stop and wait for all WAL segments to archive
2026-01-16 14:57:54.097 P00   INFO: backup stop archive = 00000001000000000000000E, lsn = 0/E000120
2026-01-16 14:57:54.128 P00   INFO: check archive for segment(s) 00000001000000000000000E:00000001000000000000000E
2026-01-16 14:57:54.434 P00   INFO: new backup label = 20260116-145747F
2026-01-16 14:57:54.829 P00   INFO: full backup size = 47.7MB, file total = 1285
2026-01-16 14:57:54.829 P00   INFO: backup command end: completed successfully (7479ms)
2026-01-16 14:57:54.829 P00   INFO: expire command begin 2.55.1: --exec-id=385560-0553f49c --log-level-console=info --log-level-file=detail --log-path=/var/log/pgbackrest --repo1-path=/pgbackrest/pg17_cluster --repo1-retention-archive=14 --repo1-retention-diff=7 --repo1-retention-full=4 --repo1-s3-bucket=btse-stg-pgbackrest-backup --repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com --repo1-s3-key-type=auto --repo1-s3-region=ap-northeast-1 --repo1-type=s3 --stanza=pg17_cluster
2026-01-16 14:57:54.912 P00   INFO: expire command end: completed successfully (83ms)
[2026-01-16 14:57:54] full backup completed from standby
[2026-01-16 14:57:54] INFO: Verifying backup...

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

[2026-01-16 14:57:55] INFO: State saved: INITIAL_BACKUP_COMPLETED=true
[2026-01-16 14:57:55] INFO: State saved: LAST_BACKUP_TYPE=full
[2026-01-16 14:57:55] INFO: State saved: LAST_BACKUP_DATE="2026-01-16 14:57:55"
[2026-01-16 14:57:55] INFO: State saved: BACKUP_FROM_STANDBY=true
[2026-01-16 14:57:55] INFO: State saved: STANZA_NAME=pg17_cluster

[2026-01-16 14:57:55] === Setting up periodic snapshots from standby ===
[2026-01-16 14:57:55] INFO: Scheduled backup script created: /root/scheduled_standby_backup.sh
[2026-01-16 14:57:55] INFO:
[2026-01-16 14:57:55] INFO: To enable automatic backups from standby, add to crontab:
[2026-01-16 14:57:55] INFO:   # Daily backup from standby at 3 AM (full on Sunday, incremental Mon-Sat)
[2026-01-16 14:57:55] INFO:   0 3 * * * /root/scheduled_standby_backup.sh
[2026-01-16 14:57:55] INFO: State saved: PERIODIC_SNAPSHOTS_CONFIGURED=true
[2026-01-16 14:57:55] Periodic snapshot setup completed

[2026-01-16 14:57:55] === STANDBY BACKUP SETUP COMPLETED SUCCESSFULLY! ===

[2026-01-16 14:57:55] INFO: === CONFIGURATION SUMMARY ===
[2026-01-16 14:57:55] INFO: Primary Server: 10.41.241.74
[2026-01-16 14:57:55] INFO: Standby Server: 10.41.241.191 (this server)
[2026-01-16 14:57:55] INFO: PostgreSQL Version: 17
[2026-01-16 14:57:55] INFO: Data Directory: /dbdata/pgsql/17/data
[2026-01-16 14:57:55] INFO: Stanza Name: pg17_cluster
[2026-01-16 14:57:55] INFO: Storage Type: s3
[2026-01-16 14:57:55] INFO: S3 Bucket: btse-stg-pgbackrest-backup
[2026-01-16 14:57:55] INFO: S3 Region: ap-northeast-1
[2026-01-16 14:57:55] INFO: S3 Path: /pgbackrest/pg17_cluster

[2026-01-16 14:57:55] INFO: === REPMGR CLUSTER STATUS ===
 ID | Name    | Role    | Status    | Upstream | Location | Priority | Timeline | Connection string
----+---------+---------+-----------+----------+----------+----------+----------+----------------------------------------------------------------
 1  | primary | primary | * running |          | default  | 100      | 1        | host=10.41.241.74 user=repmgr dbname=repmgr connect_timeout=2
 2  | standby | standby |   running | primary  | default  | 100      | 1        | host=10.41.241.191 user=repmgr dbname=repmgr connect_timeout=2

[2026-01-16 14:57:55] INFO: === STATE FILE ===
[2026-01-16 14:57:55] INFO: Configuration saved to: /root/pgbackrest_standby_backup_state.env
[2026-01-16 14:57:55] INFO: This file is needed for pgbackrest_standby_setup.sh

[2026-01-16 14:57:55] INFO: === NEXT STEPS ===
[2026-01-16 14:57:55] INFO: 1. Restore from S3 backup:
[2026-01-16 14:57:55] INFO:    sudo -u postgres pgbackrest --stanza=pg17_cluster restore
[2026-01-16 14:57:55] INFO: 2. Enable scheduled backups (optional):
[2026-01-16 14:57:55] INFO:    echo '0 3 * * * /root/scheduled_standby_backup.sh' | crontab -
[2026-01-16 14:57:55] INFO: 3. Monitor backup status:
[2026-01-16 14:57:55] INFO:    sudo -u postgres pgbackrest --stanza=pg17_cluster info

[2026-01-16 14:57:55] INFO: === IMPORTANT NOTES ===
[2026-01-16 14:57:55] INFO: - Backups are taken from standby to reduce primary load
[2026-01-16 14:57:55] INFO: - Standby backups may take longer than primary backups
[2026-01-16 14:57:55] INFO: - S3 backups provide durable, off-site storage
[2026-01-16 14:57:55] INFO: - S3 path: s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster

[2026-01-16 14:57:55] Log saved to: /root/pgbackrest_standby_backup_20260116_145735.log
[2026-01-16 14:57:55] Execution completed successfully!
```

### 13.3 S3 Contents After Backup

```bash
[root@tyo-aws-stg-binary-option-db-0002 ~]# aws s3 ls s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster/ --recursive
2026-01-16 14:57:42    710 pgbackrest/pg17_cluster/archive/pg17_cluster/17-1/0000000100000000/00000001000000000000000B-fa652c28f1e64e3e980025d54ba262d9ef047604.zst
2026-01-16 14:57:43    700 pgbackrest/pg17_cluster/archive/pg17_cluster/17-1/0000000100000000/00000001000000000000000C-7987ffff53e4faa26df47cab8ac474d729666d50.zst
2026-01-16 14:57:48    617 pgbackrest/pg17_cluster/archive/pg17_cluster/17-1/0000000100000000/00000001000000000000000D-87defc0de8cfca252aca97c1757fb43bbeb531b0.zst
2026-01-16 14:57:55    699 pgbackrest/pg17_cluster/archive/pg17_cluster/17-1/0000000100000000/00000001000000000000000E-9f6e9d037dca9f0792b1b63da372d052c1810083.zst
2026-01-16 14:57:55    371 pgbackrest/pg17_cluster/archive/pg17_cluster/17-1/0000000100000000/00000001000000000000000E.00000028.backup
2026-01-16 14:57:55    255 pgbackrest/pg17_cluster/archive/pg17_cluster/archive.info
2026-01-16 14:57:55    255 pgbackrest/pg17_cluster/archive/pg17_cluster/archive.info.copy
2026-01-16 14:57:55 218451 pgbackrest/pg17_cluster/backup/pg17_cluster/20260116-145747F/backup.manifest
2026-01-16 14:57:55 218451 pgbackrest/pg17_cluster/backup/pg17_cluster/20260116-145747F/backup.manifest.copy
2026-01-16 14:57:50     12 pgbackrest/pg17_cluster/backup/pg17_cluster/20260116-145747F/pg_data/PG_VERSION.zst
2026-01-16 14:57:55    188 pgbackrest/pg17_cluster/backup/pg17_cluster/20260116-145747F/pg_data/backup_label.zst
...
```

### 13.4 Summary

| Mode | Backup Duration | Backup Size | Compressed Size | Key Resources |
|------|-----------------|-------------|-----------------|---------------|
| **EBS** | ~4 seconds | 30.5MB | 3.7MB | vol-0ec0b70e6682ed5cf, snap-03327404502cd8b25 |
| **S3** | ~7 seconds | 47.7MB | 4.1MB | s3://btse-stg-pgbackrest-backup/pgbackrest/pg17_cluster |

**Key Configuration for S3:**
```ini
repo1-type=s3
repo1-s3-bucket=btse-stg-pgbackrest-backup
repo1-s3-region=ap-northeast-1
repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com
repo1-s3-key-type=auto    # IMPORTANT: Use IAM role authentication
repo1-path=/pgbackrest/pg17_cluster
```

---

**End of Document**
