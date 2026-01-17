# pgBackRest S3 Standby Restore - Complete Setup Guide

## Overview

This guide documents how to set up a new PostgreSQL standby server from an S3 backup using pgBackRest. This is useful for:
- Disaster recovery scenarios
- Adding new standbys to an existing cluster
- Setting up a new environment from backup

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        pgBackRest S3 Restore Architecture                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌──────────────────┐                                                      │
│   │   S3 Bucket      │                                                      │
│   │   (Backup Store) │                                                      │
│   │                  │                                                      │
│   │  /pgbackrest/    │                                                      │
│   │    └─stanza/     │                                                      │
│   │      ├─archive/  │◄─────── WAL Archives                                 │
│   │      └─backup/   │◄─────── Base Backups                                 │
│   └────────┬─────────┘                                                      │
│            │                                                                 │
│            │ Restore                                                         │
│            ▼                                                                 │
│   ┌──────────────────┐      Streaming          ┌──────────────────┐        │
│   │   PRIMARY        │      Replication        │   NEW STANDBY    │        │
│   │   10.41.241.74   │ ─────────────────────► │   10.41.241.171  │        │
│   │                  │                         │                  │        │
│   │  PostgreSQL 17   │                         │  PostgreSQL 17   │        │
│   │  (Read/Write)    │                         │  (Hot Standby)   │        │
│   └──────────────────┘                         └──────────────────┘        │
│            │                                                                 │
│            │ Streaming Replication                                          │
│            ▼                                                                 │
│   ┌──────────────────┐                                                      │
│   │ EXISTING STANDBY │                                                      │
│   │   10.41.241.191  │                                                      │
│   │                  │                                                      │
│   │  PostgreSQL 17   │                                                      │
│   │  (Hot Standby)   │                                                      │
│   └──────────────────┘                                                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### 1. AWS Infrastructure
- EC2 instance for new standby (Amazon Linux 2023 or RHEL-compatible)
- IAM role attached to instance with S3 read access
- Security group allowing:
  - Port 5432 (PostgreSQL) between cluster nodes
  - Port 22 (SSH) for script execution

### 2. S3 Bucket with Existing Backup
- pgBackRest backup already configured on primary
- At least one full backup completed
- WAL archiving enabled and working

### 3. SSH Key Configuration
The script requires passwordless SSH between servers:
```bash
# On new standby - generate SSH keys
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# Copy to PRIMARY
ssh-copy-id root@<PRIMARY_IP>

# For postgres user
sudo -u postgres ssh-keygen -t rsa -b 4096 -N "" -f /var/lib/pgsql/.ssh/id_rsa
# Copy existing postgres keys from another standby or configure manually

# Allow localhost SSH (required by script)
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

## Script Installation

### Download Script from S3
```bash
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/6_pgbackrest_standby_setup.sh /tmp/
chmod +x /tmp/6_pgbackrest_standby_setup.sh
```

### Or Create Locally
The script is located at: `6_pgbackrest_standby_setup.sh`

## Environment Variables

### Required Variables for S3 Restore

| Variable | Description | Example |
|----------|-------------|---------|
| `RESTORE_SOURCE` | Restore source type | `s3` |
| `S3_BUCKET` | S3 bucket name with backups | `btse-stg-pgbackrest-backup` |
| `S3_REGION` | AWS region of bucket | `ap-northeast-1` |
| `PRIMARY_IP` | IP address of primary server | `10.41.241.74` |
| `EXISTING_STANDBY_IP` | IP of existing standby (for reference) | `10.41.241.191` |
| `NEW_STANDBY_IP` | IP of new standby server | `10.41.241.171` |
| `NEW_NODE_ID` | Node ID for repmgr (unique integer) | `3` |
| `NEW_NODE_NAME` | Node name for replication | `standby3` |
| `RECOVERY_TARGET` | Recovery target | `latest` |

### Optional Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PG_VERSION` | PostgreSQL major version | `17` |
| `STANZA_NAME` | pgBackRest stanza name | `pg17_cluster` |
| `PG_DATA_DIR` | PostgreSQL data directory | `/dbdata/pgsql/17/data` |
| `AWS_REGION` | AWS region for operations | `ap-northeast-1` |

## Step-by-Step Execution

### Step 1: Prepare the New Server

```bash
# Install PostgreSQL 17
sudo dnf install -y postgresql17-server postgresql17

# Install pgBackRest (compile from source for Amazon Linux 2023)
sudo dnf install -y gcc make openssl-devel libxml2-devel lz4-devel zstd-devel bzip2-devel libyaml-devel libzstd-devel postgresql17-devel meson ninja-build

cd /tmp
curl -L https://github.com/pgbackrest/pgbackrest/archive/release/2.55.1.tar.gz | tar xz
cd pgbackrest-release-2.55.1
meson setup build
cd build
ninja
sudo ninja install
```

### Step 2: Configure Environment Variables

```bash
cd /tmp

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

### Step 3: Run the Script

```bash
./6_pgbackrest_standby_setup.sh
```

### Step 4: Verify Setup

```bash
# Check PostgreSQL is running
sudo -u postgres pg_ctl -D /dbdata/pgsql/17/data status

# Check it's in recovery mode
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

# Check WAL positions
sudo -u postgres psql -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# Check replication on primary
sudo -u postgres psql -h 10.41.241.74 -U repmgr -d postgres -c "SELECT application_name, client_addr, state FROM pg_stat_replication;"
```

## Script Execution Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Script Execution Steps                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  STEP 1-3: Skipped for S3 restore (EBS snapshot steps)                      │
│                                                                              │
│  STEP 4: Install pgBackRest                                                 │
│    └─► Verifies PostgreSQL & pgBackRest installation                        │
│                                                                              │
│  STEP 5: Configure pgBackRest                                               │
│    └─► Creates /etc/pgbackrest/pgbackrest.conf with S3 settings             │
│                                                                              │
│  STEP 6: Restore Database                                                   │
│    ├─► Configures S3 access (IAM role: repo1-s3-key-type=auto)              │
│    ├─► Clears existing data directory                                       │
│    ├─► Runs: pgbackrest --stanza=<stanza> --delta restore                   │
│    └─► Configures standby.signal and postgresql.conf                        │
│                                                                              │
│  STEP 7: Setup Replication Slot                                             │
│    ├─► Creates physical replication slot on primary                         │
│    └─► Updates pg_hba.conf on primary                                       │
│                                                                              │
│  STEP 8: Configure & Start Standby                                          │
│    ├─► Configures pg_hba.conf                                               │
│    ├─► Starts PostgreSQL using pg_ctl                                       │
│    └─► Verifies recovery mode                                               │
│                                                                              │
│  STEP 9: Register with repmgr (if available)                                │
│    └─► Registers standby with cluster manager                               │
│                                                                              │
│  STEP 10: Final Verification                                                │
│    ├─► Checks replication status                                            │
│    ├─► Verifies WAL streaming                                               │
│    └─► Creates test table for replication verification                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## pgBackRest S3 Configuration

The script creates this configuration on the new standby:

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
repo1-s3-key-type=auto                    # Uses IAM role (no keys needed)
repo1-path=/pgbackrest/pg17_cluster       # Path in S3 bucket

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

## S3 Bucket Structure

```
s3://btse-stg-pgbackrest-backup/
└── pgbackrest/
    └── pg17_cluster/                    # Stanza name
        ├── archive/
        │   └── pg17_cluster/
        │       └── 17-1/
        │           └── 0000000100000000/
        │               ├── 00000001000000000000000B-*.zst
        │               └── ...
        └── backup/
            └── pg17_cluster/
                └── 20260116-145747F/    # Full backup
                    ├── backup.manifest
                    └── pg_data/
                        └── ...
```

## Troubleshooting

### Issue: "missing stanza path" Error
```
stanza: pg17_cluster
    status: error (missing stanza path)
```
**Solution:** Check `repo1-path` in pgbackrest.conf. It should match the S3 path structure:
```ini
repo1-path=/pgbackrest/pg17_cluster
```

### Issue: "repo1-s3-key" Required
```
ERROR: info command requires option: repo1-s3-key
```
**Solution:** Add IAM role authentication:
```ini
repo1-s3-key-type=auto
```

### Issue: PostgreSQL Not Starting
**Solution:** Start manually with pg_ctl:
```bash
sudo -u postgres /usr/bin/pg_ctl -D /dbdata/pgsql/17/data -l /dbdata/pgsql/17/data/log/startup.log start
```

### Issue: SSH Password Prompt
**Solution:** Set up SSH keys:
```bash
# Generate keys
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# Copy to other servers
ssh-copy-id root@<PRIMARY_IP>

# Allow localhost
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
```

### Issue: Replication Not Working
**Check on Primary:**
```bash
# Check replication slots
sudo -u postgres psql -c "SELECT slot_name, active FROM pg_replication_slots;"

# Check pg_hba.conf has entry for new standby IP
grep <NEW_STANDBY_IP> /dbdata/pgsql/17/data/pg_hba.conf
```

**Check on Standby:**
```bash
# Check primary_conninfo
grep primary_conninfo /dbdata/pgsql/17/data/postgresql.conf

# Check standby.signal exists
ls -la /dbdata/pgsql/17/data/standby.signal
```

## Monitoring Commands

### Check Replication Status (on Primary)
```bash
sudo -u postgres psql -c "
SELECT application_name,
       client_addr,
       state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       sync_state
FROM pg_stat_replication;"
```

### Check Recovery Status (on Standby)
```bash
sudo -u postgres psql -c "
SELECT pg_is_in_recovery() as is_standby,
       pg_last_wal_receive_lsn() as receive_lsn,
       pg_last_wal_replay_lsn() as replay_lsn,
       pg_last_xact_replay_timestamp() as last_replay_time;"
```

### Check pgBackRest Backup Info
```bash
sudo -u postgres pgbackrest --stanza=pg17_cluster info
```

## Quick Reference

### Complete Setup Commands
```bash
# 1. SSH to new standby server
aws ssm start-session --target <INSTANCE_ID> --region ap-northeast-1

# 2. Download script
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/6_pgbackrest_standby_setup.sh /tmp/
chmod +x /tmp/6_pgbackrest_standby_setup.sh

# 3. Set environment variables
cd /tmp
export RESTORE_SOURCE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export S3_REGION="ap-northeast-1"
export PRIMARY_IP="<PRIMARY_IP>"
export EXISTING_STANDBY_IP="<EXISTING_STANDBY_IP>"
export NEW_STANDBY_IP="<NEW_STANDBY_IP>"
export NEW_NODE_ID="<UNIQUE_NUMBER>"
export NEW_NODE_NAME="standby<NUMBER>"
export RECOVERY_TARGET="latest"

# 4. Run script
./6_pgbackrest_standby_setup.sh

# 5. Verify
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
```

## Related Documentation

| Document | Description |
|----------|-------------|
| `1_PostgreSQL_17_HA_Deployment_Runbook.md` | Initial HA cluster setup |
| `3_pgBackRest_Standby_Backup_Setup_Runbook.md` | Backup configuration (EBS + S3) |
| `4_pgbackrest_standby_backup_setup.sh` | Backup setup script |
| `5_pgBackRest_Standby_Restore_Setup_Runbook.md` | Restore procedures |
| `6_pgbackrest_standby_setup.sh` | This restore script |

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.0 | 2026-01-16 | Added S3 restore support, fixed PostgreSQL auto-start |
| 1.0 | 2025-12-18 | Initial EBS-based restore |

---

**Script Location:** `s3://btse-stg-pgbackrest-backup/scripts/6_pgbackrest_standby_setup.sh`

**Last Updated:** 2026-01-17
