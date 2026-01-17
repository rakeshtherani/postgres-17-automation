# PostgreSQL 17 High Availability Complete Deployment Guide

## A Step-by-Step Guide to Building Enterprise-Grade PostgreSQL HA Clusters

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Architecture Overview](#2-architecture-overview)
3. [Prerequisites](#3-prerequisites)
4. [Phase 1: PostgreSQL 17 HA Cluster Setup](#4-phase-1-postgresql-17-ha-cluster-setup)
5. [Phase 2: pgBackRest Backup Configuration](#5-phase-2-pgbackrest-backup-configuration)
6. [Phase 3: Adding New Standby from S3 Backup](#6-phase-3-adding-new-standby-from-s3-backup)
7. [Phase 4: ProxySQL Load Balancer Setup](#7-phase-4-proxysql-load-balancer-setup)
8. [Monitoring and Operations](#8-monitoring-and-operations)
9. [Disaster Recovery Procedures](#9-disaster-recovery-procedures)
10. [Scripts Reference](#10-scripts-reference)
11. [Troubleshooting Guide](#11-troubleshooting-guide)

---

## 1. Introduction

This guide provides a complete, production-ready deployment of a PostgreSQL 17 High Availability cluster with:

- **Streaming Replication**: Real-time data replication to standby servers
- **pgBackRest**: Enterprise backup solution with S3 storage
- **ProxySQL**: Intelligent query routing and connection pooling
- **Automated Recovery**: Scripts for disaster recovery scenarios

### What You'll Build

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PostgreSQL 17 HA Architecture                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         ProxySQL Layer                               │   │
│   │   ┌─────────────────┐                                               │   │
│   │   │   ProxySQL      │  Port 6133 (App)                              │   │
│   │   │   Load Balancer │  Port 6132 (Admin)                            │   │
│   │   └────────┬────────┘                                               │   │
│   │            │                                                         │   │
│   │            │ Query Routing                                          │   │
│   │            │ ├── Writes → Primary (Hostgroup 1)                     │   │
│   │            │ └── Reads  → Standbys (Hostgroup 2)                    │   │
│   └────────────┼────────────────────────────────────────────────────────┘   │
│                │                                                             │
│   ┌────────────┴────────────────────────────────────────────────────────┐   │
│   │                     PostgreSQL Cluster                               │   │
│   │                                                                      │   │
│   │  ┌──────────────┐   Streaming    ┌──────────────┐                   │   │
│   │  │   PRIMARY    │   Replication  │   STANDBY1   │                   │   │
│   │  │ 10.41.241.74 │ ─────────────► │10.41.241.191 │                   │   │
│   │  │              │                │              │                   │   │
│   │  │ PostgreSQL 17│                │ PostgreSQL 17│                   │   │
│   │  │ (Read/Write) │                │ (Hot Standby)│                   │   │
│   │  └──────┬───────┘                └──────────────┘                   │   │
│   │         │                                                            │   │
│   │         │ Streaming                                                  │   │
│   │         │ Replication            ┌──────────────┐                   │   │
│   │         └───────────────────────►│   STANDBY2   │                   │   │
│   │                                  │10.41.241.171 │                   │   │
│   │                                  │              │                   │   │
│   │                                  │ PostgreSQL 17│                   │   │
│   │                                  │ (Hot Standby)│                   │   │
│   │                                  └──────────────┘                   │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                │                                                             │
│   ┌────────────┴────────────────────────────────────────────────────────┐   │
│   │                      Backup Layer (pgBackRest)                       │   │
│   │                                                                      │   │
│   │  ┌────────────────────────────────────────────────────────────┐     │   │
│   │  │                    S3 Bucket                                │     │   │
│   │  │         btse-stg-pgbackrest-backup                         │     │   │
│   │  │                                                             │     │   │
│   │  │  /pgbackrest/pg17_cluster/                                 │     │   │
│   │  │    ├── archive/  ← WAL Archives (Continuous)               │     │   │
│   │  │    └── backup/   ← Full/Incremental Backups                │     │   │
│   │  └────────────────────────────────────────────────────────────┘     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Architecture Overview

### Components

| Component | Purpose | Version |
|-----------|---------|---------|
| PostgreSQL | Database Server | 17.7 |
| pgBackRest | Backup & Recovery | 2.55.1 |
| ProxySQL | Load Balancer & Connection Pooling | 3.0.2 |
| Amazon Linux 2023 | Operating System | Latest |
| AWS S3 | Backup Storage | - |

### Server Inventory

| Role | Hostname | IP Address | Instance ID |
|------|----------|------------|-------------|
| Primary | tyo-aws-stg-binary-option-db-0001 | 10.41.241.74 | i-052b680cf24be321e |
| Standby 1 | tyo-aws-stg-binary-option-db-0002 | 10.41.241.191 | i-013fe40421853b6b0 |
| Standby 2 | tyo-aws-stg-binary-option-db-0003 | 10.41.241.171 | i-05c2a08b24488f2ba |

### Network Configuration

| Port | Service | Access |
|------|---------|--------|
| 5432 | PostgreSQL | Cluster Internal |
| 6132 | ProxySQL Admin | Admin Only |
| 6133 | ProxySQL PostgreSQL | Application |
| 22 | SSH | Management |

---

## 3. Prerequisites

### AWS Requirements

1. **EC2 Instances**: 3x instances for PostgreSQL cluster
2. **IAM Role**: S3 read/write access for pgBackRest
3. **S3 Bucket**: For backup storage
4. **Security Groups**: Allow ports 5432, 22 between cluster nodes

### Software Requirements

- PostgreSQL 17
- pgBackRest 2.55.1
- ProxySQL 3.0.2 (optional)

### SSH Key Configuration (CRITICAL)

**IMPORTANT**: Passwordless SSH must be configured for BOTH `root` and `postgres` users across ALL cluster nodes. This is required for:
- pgBackRest backup operations
- Standby restore scripts
- ProxySQL setup scripts
- repmgr cluster management

#### Step 1: Setup SSH Keys for ROOT User (on EACH server)

```bash
# Generate SSH key (if not exists)
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# Copy to ALL other cluster nodes
ssh-copy-id root@10.41.241.74    # Primary
ssh-copy-id root@10.41.241.191   # Standby 1
ssh-copy-id root@10.41.241.171   # Standby 2

# Allow localhost SSH (required by scripts)
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Test connections
ssh -o StrictHostKeyChecking=no root@10.41.241.74 hostname
ssh -o StrictHostKeyChecking=no root@10.41.241.191 hostname
ssh -o StrictHostKeyChecking=no root@10.41.241.171 hostname
```

#### Step 2: Setup SSH Keys for POSTGRES User (on EACH server)

```bash
# Create .ssh directory for postgres user
sudo mkdir -p /var/lib/pgsql/.ssh
sudo chown postgres:postgres /var/lib/pgsql/.ssh
sudo chmod 700 /var/lib/pgsql/.ssh

# Generate SSH key for postgres user
sudo -u postgres ssh-keygen -t rsa -b 4096 -N "" -f /var/lib/pgsql/.ssh/id_rsa

# Copy to ALL other cluster nodes
sudo -u postgres ssh-copy-id postgres@10.41.241.74
sudo -u postgres ssh-copy-id postgres@10.41.241.191
sudo -u postgres ssh-copy-id postgres@10.41.241.171

# Allow localhost SSH
sudo -u postgres bash -c 'cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys'
sudo chmod 600 /var/lib/pgsql/.ssh/authorized_keys

# Test connections
sudo -u postgres ssh -o StrictHostKeyChecking=no postgres@10.41.241.74 hostname
sudo -u postgres ssh -o StrictHostKeyChecking=no postgres@10.41.241.191 hostname
sudo -u postgres ssh -o StrictHostKeyChecking=no postgres@10.41.241.171 hostname
```

#### Quick Copy Method (Alternative)

If you already have working SSH keys on one server, you can copy them:

```bash
# Copy from existing standby to new server (as root)
scp /var/lib/pgsql/.ssh/id_rsa* root@NEW_SERVER:/var/lib/pgsql/.ssh/
ssh root@NEW_SERVER "chown postgres:postgres /var/lib/pgsql/.ssh/*"
```

#### Verification Checklist

Run from each server to verify passwordless SSH:

```bash
# As root
for host in 10.41.241.74 10.41.241.191 10.41.241.171; do
  echo -n "Root SSH to $host: "
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@$host hostname 2>/dev/null && echo "OK" || echo "FAILED"
done

# As postgres
for host in 10.41.241.74 10.41.241.191 10.41.241.171; do
  echo -n "Postgres SSH to $host: "
  sudo -u postgres ssh -o BatchMode=yes -o StrictHostKeyChecking=no postgres@$host hostname 2>/dev/null && echo "OK" || echo "FAILED"
done
```

---

## 4. Phase 1: PostgreSQL 17 HA Cluster Setup

### Step 1: Install PostgreSQL 17 on All Nodes

```bash
# For Amazon Linux 2023
sudo dnf install -y postgresql17-server postgresql17

# Initialize database (PRIMARY only)
sudo -u postgres /usr/pgsql-17/bin/initdb -D /dbdata/pgsql/17/data

# Start PostgreSQL
sudo -u postgres /usr/bin/pg_ctl -D /dbdata/pgsql/17/data start
```

### Step 2: Configure Primary Server

```bash
# Edit postgresql.conf
cat >> /dbdata/pgsql/17/data/postgresql.conf << EOF

# Replication Settings
wal_level = replica
max_wal_senders = 16
max_replication_slots = 16
hot_standby = on
archive_mode = on
archive_command = 'pgbackrest --stanza=pg17_cluster archive-push %p'

# Performance
max_connections = 600
shared_buffers = 4GB
effective_cache_size = 12GB
EOF

# Edit pg_hba.conf for replication
cat >> /dbdata/pgsql/17/data/pg_hba.conf << EOF

# Replication connections
host    replication     repmgr          10.41.241.0/24          scram-sha-256
host    repmgr          repmgr          10.41.241.0/24          scram-sha-256
EOF

# Restart PostgreSQL
sudo -u postgres pg_ctl -D /dbdata/pgsql/17/data restart
```

### Step 3: Create Replication User

```sql
-- On PRIMARY
CREATE USER repmgr WITH REPLICATION PASSWORD 'your_secure_password';
CREATE DATABASE repmgr OWNER repmgr;
```

### Step 4: Setup Standby Servers

```bash
# On STANDBY servers - use pg_basebackup
sudo -u postgres pg_basebackup -h 10.41.241.74 -D /dbdata/pgsql/17/data -U repmgr -Fp -Xs -P -R

# Start standby
sudo -u postgres pg_ctl -D /dbdata/pgsql/17/data start
```

### Step 5: Verify Replication

```sql
-- On PRIMARY
SELECT application_name, client_addr, state, sync_state
FROM pg_stat_replication;

-- Expected output:
--  application_name |  client_addr  |   state   | sync_state
-- ------------------+---------------+-----------+------------
--  standby          | 10.41.241.191 | streaming | async
--  standby3         | 10.41.241.171 | streaming | async
```

---

## 5. Phase 2: pgBackRest Backup Configuration

### Step 1: Install pgBackRest

```bash
# For Amazon Linux 2023 (compile from source)
cd /tmp
curl -L https://github.com/pgbackrest/pgbackrest/archive/release/2.55.1.tar.gz | tar xz
cd pgbackrest-release-2.55.1
meson setup build
cd build
ninja
sudo ninja install
```

### Step 2: Configure pgBackRest for S3

Create `/etc/pgbackrest/pgbackrest.conf`:

```ini
[pg17_cluster]
pg1-path=/dbdata/pgsql/17/data
pg1-port=5432

[global]
# S3 Repository
repo1-type=s3
repo1-s3-bucket=btse-stg-pgbackrest-backup
repo1-s3-region=ap-northeast-1
repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com
repo1-s3-key-type=auto
repo1-path=/pgbackrest/pg17_cluster

# Retention
repo1-retention-full=7
repo1-retention-diff=14

# Performance
process-max=8
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest

[global:archive-push]
compress-level=3
```

### Step 3: Initialize Stanza

```bash
# Create stanza
sudo -u postgres pgbackrest --stanza=pg17_cluster stanza-create

# Verify configuration
sudo -u postgres pgbackrest --stanza=pg17_cluster check
```

### Step 4: Create First Backup

```bash
# Full backup
sudo -u postgres pgbackrest --stanza=pg17_cluster --type=full backup

# Verify backup
sudo -u postgres pgbackrest --stanza=pg17_cluster info
```

### Step 5: Setup Backup Schedule

```bash
# Add to crontab
sudo -u postgres crontab -e

# Add these entries:
# Full backup - Sunday 2 AM
0 2 * * 0 /usr/bin/pgbackrest --stanza=pg17_cluster --type=full backup

# Differential backup - Daily 2 AM (except Sunday)
0 2 * * 1-6 /usr/bin/pgbackrest --stanza=pg17_cluster --type=diff backup
```

---

## 6. Phase 3: Adding New Standby from S3 Backup

This is the key feature - restoring a new standby server directly from S3 backup.

### Step 1: Prepare New Server

```bash
# Install PostgreSQL 17
sudo dnf install -y postgresql17-server postgresql17

# Install pgBackRest (compile from source - see above)
```

### Step 2: Configure SSH Keys

```bash
# Generate keys
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# Copy to PRIMARY
ssh-copy-id root@10.41.241.74

# Allow localhost SSH
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
```

### Step 3: Run Restore Script

```bash
# Download script from S3
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/6_pgbackrest_standby_setup.sh /tmp/
chmod +x /tmp/6_pgbackrest_standby_setup.sh

# Set environment variables
export RESTORE_SOURCE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export S3_REGION="ap-northeast-1"
export PRIMARY_IP="10.41.241.74"
export EXISTING_STANDBY_IP="10.41.241.191"
export NEW_STANDBY_IP="10.41.241.171"
export NEW_NODE_ID="3"
export NEW_NODE_NAME="standby3"
export RECOVERY_TARGET="latest"

# Run script
./6_pgbackrest_standby_setup.sh
```

### Step 4: Verify New Standby

```bash
# Check recovery mode
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

# Check WAL positions
sudo -u postgres psql -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# Check replication on PRIMARY
sudo -u postgres psql -h 10.41.241.74 -c "SELECT application_name, client_addr, state FROM pg_stat_replication;"
```

---

## 7. Phase 4: ProxySQL Load Balancer Setup

### Step 1: Install ProxySQL

```bash
# Download and install
cd /tmp
curl -LO https://github.com/sysown/proxysql/releases/download/v3.0.2/proxysql-3.0.2-1-almalinux9.x86_64.rpm
rpm -ivh --nodeps proxysql-3.0.2-1-almalinux9.x86_64.rpm
```

### Step 2: Run Setup Script

```bash
# Download script
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/8_setup_proxysql_postgresql17.sh /tmp/
chmod +x /tmp/8_setup_proxysql_postgresql17.sh

# Set environment variables
export PRIMARY_HOST="10.41.241.74"
export STANDBY1_HOST="10.41.241.191"
export STANDBY2_HOST="10.41.241.171"
export APP_USER="app_user"
export APP_PASS="YourSecurePassword"

# Run script
./8_setup_proxysql_postgresql17.sh
```

### Step 3: Verify ProxySQL

```bash
# Check admin interface
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
SELECT hostgroup_id, hostname, port, status
FROM runtime_pgsql_servers;"

# Test application connection
PGPASSWORD=YourSecurePassword psql -h 127.0.0.1 -p 6133 -U app_user -d postgres -c "SELECT 1;"
```

### Query Routing Configuration

| Query Type | Destination | Hostgroup |
|------------|-------------|-----------|
| SELECT | Standbys (load balanced) | 2 |
| INSERT/UPDATE/DELETE | Primary | 1 |
| BEGIN/COMMIT/ROLLBACK | Primary | 1 |
| CREATE/DROP/ALTER | Primary | 1 |

---

## 8. Monitoring and Operations

### Daily Health Checks

```bash
# Check replication status
sudo -u postgres psql -c "
SELECT application_name, client_addr, state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) as lag_bytes
FROM pg_stat_replication;"

# Check backup status
sudo -u postgres pgbackrest --stanza=pg17_cluster info

# Check ProxySQL connection pool
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, ConnOK, ConnERR
FROM stats_pgsql_connection_pool;"
```

### Monitoring Queries

```sql
-- Replication lag in seconds
SELECT application_name,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as lag_bytes,
       EXTRACT(EPOCH FROM (now() - replay_lag)) as lag_seconds
FROM pg_stat_replication;

-- Database size
SELECT pg_size_pretty(pg_database_size('postgres'));

-- Active connections
SELECT count(*) FROM pg_stat_activity WHERE state = 'active';
```

---

## 9. Disaster Recovery Procedures

### Scenario 1: Primary Failure - Promote Standby

```bash
# On standby to promote
sudo -u postgres pg_ctl promote -D /dbdata/pgsql/17/data

# Verify new primary
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Should return: f (false)
```

### Scenario 2: Complete Cluster Restore from S3

```bash
# On new server
export RESTORE_SOURCE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export RECOVERY_TARGET="latest"  # or specific time

# Restore
sudo -u postgres pgbackrest --stanza=pg17_cluster --delta restore
```

### Scenario 3: Point-in-Time Recovery

```bash
# Restore to specific time
sudo -u postgres pgbackrest --stanza=pg17_cluster \
    --target="2026-01-16 14:30:00" \
    --target-action=promote \
    restore
```

---

## 10. Scripts Reference

| Script | Purpose | Location |
|--------|---------|----------|
| `1_PostgreSQL_17_HA_Deployment_Runbook.md` | Initial HA cluster setup | Local |
| `3_pgBackRest_Standby_Backup_Setup_Runbook.md` | Backup configuration | Local |
| `4_pgbackrest_standby_backup_setup.sh` | Backup setup automation | S3 |
| `6_pgbackrest_standby_setup.sh` | S3 standby restore | S3 |
| `7_pgBackRest_S3_Standby_Restore_Complete_Guide.md` | S3 restore documentation | S3/Local |
| `8_setup_proxysql_postgresql17.sh` | ProxySQL setup | S3 |
| `verify_proxysql.sh` | ProxySQL health check | Local |
| `monitor_proxysql.sh` | ProxySQL monitoring | Local |

### Script Locations in S3

```
s3://btse-stg-pgbackrest-backup/
├── scripts/
│   ├── 4_pgbackrest_standby_backup_setup.sh
│   ├── 6_pgbackrest_standby_setup.sh
│   └── 8_setup_proxysql_postgresql17.sh
└── docs/
    └── 7_pgBackRest_S3_Standby_Restore_Complete_Guide.md
```

---

## 11. Troubleshooting Guide

### Issue: Replication Lag Increasing

```bash
# Check network latency
ping -c 5 <standby_ip>

# Check WAL sender status
sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;"

# Check standby logs
tail -100 /dbdata/pgsql/17/data/log/postgresql-*.log
```

### Issue: pgBackRest S3 Access Denied

```bash
# Verify IAM role
aws sts get-caller-identity

# Check S3 access
aws s3 ls s3://btse-stg-pgbackrest-backup/

# Verify pgBackRest config has key-type=auto
grep repo1-s3-key-type /etc/pgbackrest/pgbackrest.conf
```

### Issue: ProxySQL Connection Errors

```bash
# Check backend server status
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
SELECT hostname, port, status, ConnERR
FROM stats_pgsql_connection_pool;"

# Check ProxySQL logs
tail -100 /var/log/proxysql/proxysql.log

# Verify PostgreSQL pg_hba.conf has ProxySQL entries
grep proxysql /dbdata/pgsql/17/data/pg_hba.conf
```

### Issue: PostgreSQL Won't Start After Restore

```bash
# Check for recovery.signal or standby.signal
ls -la /dbdata/pgsql/17/data/*.signal

# Check startup logs
cat /dbdata/pgsql/17/data/log/startup.log

# Verify permissions
ls -la /dbdata/pgsql/17/data/
chown -R postgres:postgres /dbdata/pgsql/17/data/
```

---

## Quick Reference Commands

```bash
# === PostgreSQL ===
# Check if standby
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

# Check replication status (on primary)
sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;"

# Promote standby
sudo -u postgres pg_ctl promote -D /dbdata/pgsql/17/data

# === pgBackRest ===
# Full backup
sudo -u postgres pgbackrest --stanza=pg17_cluster --type=full backup

# Check backup info
sudo -u postgres pgbackrest --stanza=pg17_cluster info

# Restore latest
sudo -u postgres pgbackrest --stanza=pg17_cluster --delta restore

# === ProxySQL ===
# Check servers
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c \
    "SELECT * FROM runtime_pgsql_servers;"

# Check connection pool
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c \
    "SELECT * FROM stats_pgsql_connection_pool;"
```

---

## Conclusion

This guide provides a complete, production-ready PostgreSQL 17 HA solution with:

1. **High Availability**: Streaming replication with multiple standbys
2. **Disaster Recovery**: pgBackRest with S3 storage
3. **Load Balancing**: ProxySQL for read/write splitting
4. **Automation**: Scripts for common operations

For questions or issues, refer to the troubleshooting section or check the individual runbook documents.

---

**Document Version**: 1.0
**Last Updated**: 2026-01-17
**Author**: DBA Automation Team
