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

### Automated Script: `2_generate_postgresql_17_ansible.sh`

This script generates a complete Ansible playbook for PostgreSQL + repmgr deployment with hardware-aware configuration.

### Script Options

| Option | Description | Default |
|--------|-------------|---------|
| `-c, --cpu` | CPU cores per node | 16 |
| `-r, --ram` | RAM in GB per node | 64 |
| `-p, --pg-version` | PostgreSQL version | 17 |
| `-m, --repmgr-version` | repmgr version | 5.5.0 |
| `--primary-ip` | Primary server IP | 10.41.241.74 |
| `--standby-ip` | Standby server IP | 10.41.241.191 |
| `-s, --storage` | Storage type (hdd/ssd) | hdd |
| `-d, --data-dir` | Custom data directory | /var/lib/pgsql/VERSION/data |
| `--install-postgres` | Install from PGDG repo | true |

### Step 1: Generate Ansible Playbook

```bash
# Download script
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/2_generate_postgresql_17_ansible.sh /tmp/
chmod +x /tmp/2_generate_postgresql_17_ansible.sh

# Generate playbook with your configuration
./2_generate_postgresql_17_ansible.sh \
    --cpu 16 \
    --ram 64 \
    --pg-version 17 \
    --repmgr-version 5.5.0 \
    --primary-ip 10.41.241.74 \
    --standby-ip 10.41.241.191 \
    --storage ssd \
    --data-dir /dbdata/pgsql/17/data
```

### Step 2: Run Ansible Playbook

```bash
# Navigate to generated project
cd postgresql-repmgr-ansible

# Review inventory file
cat inventory.ini

# Run the playbook
ansible-playbook -i inventory.ini site.yml
```

### What the Script Configures Automatically

The script automatically configures:

1. **PostgreSQL Installation**
   - Installs PostgreSQL 17 from PGDG repository
   - Creates custom data directory structure
   - Sets up proper permissions

2. **Performance Tuning** (based on CPU/RAM input)
   - `shared_buffers` = RAM / 4
   - `effective_cache_size` = RAM * 3/4
   - `max_connections` based on RAM
   - `work_mem`, `maintenance_work_mem` optimized

3. **Replication Settings**
   - `wal_level = replica`
   - `max_wal_senders = 16`
   - `max_replication_slots = 16`
   - `hot_standby = on`

4. **repmgr Configuration**
   - Creates repmgr user and database
   - Configures `pg_hba.conf` for replication
   - Registers primary and standby nodes
   - Sets up automatic failover

### Step 3: Verify Replication

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

### Automated Script: `4_pgbackrest_standby_backup_setup.sh`

This script handles complete pgBackRest setup including:
- Installing pgBackRest from source
- Configuring S3 or EBS backup repository
- Setting up SSH keys between nodes
- Creating initial stanza and backup
- Configuring cron schedules

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PRIMARY_IP` | Primary PostgreSQL server | 10.41.241.74 |
| `STANDBY_IP` | Standby server for backups | 10.41.241.191 |
| `PG_VERSION` | PostgreSQL version | 17 |
| `STANZA_NAME` | pgBackRest stanza name | pg17_cluster |
| `STORAGE_TYPE` | Storage type (ebs/s3) | ebs |
| `S3_BUCKET` | S3 bucket name (for S3 mode) | - |
| `S3_REGION` | S3 region | ap-northeast-1 |
| `CUSTOM_DATA_DIR` | PostgreSQL data directory | /dbdata/pgsql/17/data |
| `BACKUP_MODE` | auto/setup/full/incr/skip | auto |

### Step 1: Configure and Run Backup Setup

```bash
# Download script
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/4_pgbackrest_standby_backup_setup.sh /tmp/
chmod +x /tmp/4_pgbackrest_standby_backup_setup.sh

# Set environment variables for S3 backup
export PRIMARY_IP="10.41.241.74"
export STANDBY_IP="10.41.241.191"
export PG_VERSION="17"
export STANZA_NAME="pg17_cluster"
export STORAGE_TYPE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export S3_REGION="ap-northeast-1"
export CUSTOM_DATA_DIR="/dbdata/pgsql/17/data"

# Run script (execute on STANDBY server)
./4_pgbackrest_standby_backup_setup.sh
```

### Alternative: EBS-Based Backup

```bash
# For EBS snapshot-based backup
export STORAGE_TYPE="ebs"
export BACKUP_VOLUME_SIZE="200"
export AWS_REGION="ap-northeast-1"
export AVAILABILITY_ZONE="ap-northeast-1a"

./4_pgbackrest_standby_backup_setup.sh
```

### What the Script Configures Automatically

1. **pgBackRest Installation**
   - Compiles pgBackRest 2.55.1 from source
   - Creates log directories and configuration

2. **SSH Key Setup**
   - Configures passwordless SSH for `postgres` user
   - Sets up SSH between primary and standby

3. **pgBackRest Configuration** (auto-generated `/etc/pgbackrest/pgbackrest.conf`)
   ```ini
   [pg17_cluster]
   pg1-path=/dbdata/pgsql/17/data
   pg1-port=5432

   [global]
   repo1-type=s3
   repo1-s3-bucket=btse-stg-pgbackrest-backup
   repo1-s3-region=ap-northeast-1
   repo1-s3-endpoint=s3.ap-northeast-1.amazonaws.com
   repo1-s3-key-type=auto
   repo1-path=/pgbackrest/pg17_cluster
   repo1-retention-full=7
   repo1-retention-diff=14
   process-max=8
   ```

4. **Stanza Creation and Initial Backup**
   - Creates stanza on primary and standby
   - Takes initial full backup

5. **Cron Schedule** (auto-configured)
   ```bash
   # Full backup - Sunday 2 AM
   0 2 * * 0 /usr/bin/pgbackrest --stanza=pg17_cluster --type=full backup

   # Differential backup - Daily 2 AM (except Sunday)
   0 2 * * 1-6 /usr/bin/pgbackrest --stanza=pg17_cluster --type=diff backup
   ```

### Step 2: Verify Backup Setup

```bash
# Check backup info
sudo -u postgres pgbackrest --stanza=pg17_cluster info

# Verify WAL archiving
sudo -u postgres pgbackrest --stanza=pg17_cluster check
```

---

## 6. Phase 3: Adding New Standby from S3 Backup

### Automated Script: `6_pgbackrest_standby_setup.sh`

This script handles complete standby restoration including:
- Restoring from S3 or EBS snapshot
- Point-in-Time Recovery (PITR) support
- Configuring streaming replication
- Registering with repmgr cluster

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `RESTORE_SOURCE` | Restore source (s3/ebs) | ebs |
| `S3_BUCKET` | S3 bucket name | - |
| `S3_REGION` | S3 region | ap-northeast-1 |
| `PRIMARY_IP` | Primary PostgreSQL server | 10.41.241.74 |
| `EXISTING_STANDBY_IP` | Existing standby (for config copy) | 10.41.241.191 |
| `NEW_STANDBY_IP` | New standby server IP | - |
| `NEW_NODE_ID` | repmgr node ID for new standby | 3 |
| `NEW_NODE_NAME` | repmgr node name | standby2 |
| `RECOVERY_TARGET` | Recovery target (latest/time/immediate) | latest |
| `TARGET_TIME` | PITR timestamp (for time recovery) | - |
| `TARGET_ACTION` | Action after recovery (pause/promote/shutdown) | promote |

### Step 1: Run Standby Restore Script (S3 Mode)

```bash
# Download script from S3
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/6_pgbackrest_standby_setup.sh /tmp/
chmod +x /tmp/6_pgbackrest_standby_setup.sh

# Set environment variables for S3 restore
export RESTORE_SOURCE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export S3_REGION="ap-northeast-1"
export PRIMARY_IP="10.41.241.74"
export EXISTING_STANDBY_IP="10.41.241.191"
export NEW_STANDBY_IP="10.41.241.171"
export NEW_NODE_ID="3"
export NEW_NODE_NAME="standby3"
export RECOVERY_TARGET="latest"

# Run script (execute on NEW STANDBY server)
./6_pgbackrest_standby_setup.sh
```

### Alternative: Point-in-Time Recovery (PITR)

```bash
# Restore to specific point in time
export RESTORE_SOURCE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export RECOVERY_TARGET="time"
export TARGET_TIME="2026-01-16 14:30:00"
export TARGET_ACTION="promote"

./6_pgbackrest_standby_setup.sh
```

### Alternative: EBS Snapshot Restore

```bash
# Restore from EBS snapshot (faster for large databases)
export RESTORE_SOURCE="ebs"
export PRIMARY_IP="10.41.241.74"
export NEW_NODE_ID="3"
export NEW_NODE_NAME="standby3"

./6_pgbackrest_standby_setup.sh
```

### What the Script Configures Automatically

1. **Pre-flight Checks**
   - Verifies SSH connectivity to primary and existing standby
   - Checks S3 bucket access (for S3 mode)
   - Validates pgBackRest backup availability

2. **PostgreSQL Installation** (if needed)
   - Installs PostgreSQL 17 from PGDG repository
   - Creates data directory structure

3. **pgBackRest Configuration**
   - Copies configuration from existing standby
   - Configures S3 repository access

4. **Restore Operation**
   - Restores database from S3/EBS backup
   - Applies WAL for PITR if specified
   - Creates `standby.signal` for streaming replication

5. **Replication Setup**
   - Configures `primary_conninfo` in `postgresql.auto.conf`
   - Creates replication slot on primary
   - Starts PostgreSQL in standby mode

6. **repmgr Registration**
   - Registers new node with repmgr cluster
   - Verifies cluster status

### Step 2: Verify New Standby

```bash
# Check recovery mode
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

# Check WAL positions
sudo -u postgres psql -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# Check replication on PRIMARY
sudo -u postgres psql -h 10.41.241.74 -c "SELECT application_name, client_addr, state FROM pg_stat_replication;"

# Check repmgr cluster status
sudo -u postgres /usr/pgsql-17/bin/repmgr cluster show
```

---

## 7. Phase 4: ProxySQL Load Balancer Setup

### Automated Script: `8_setup_proxysql_postgresql17.sh`

This script handles complete ProxySQL setup including:
- Installing ProxySQL 3.0.2
- Configuring backend PostgreSQL servers
- Setting up read/write query routing
- Creating monitor and application users
- Configuring connection pooling

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PRIMARY_HOST` | Primary PostgreSQL server | 10.41.241.74 |
| `STANDBY1_HOST` | First standby server | 10.41.241.191 |
| `STANDBY2_HOST` | Second standby server | 10.41.241.171 |
| `PROXYSQL_HOST` | ProxySQL server IP | (auto-detected) |
| `PG_VERSION` | PostgreSQL version | 17 |
| `PROXYSQL_ADMIN_PORT` | Admin interface port | 6132 |
| `PROXYSQL_PGSQL_PORT` | PostgreSQL client port | 6133 |
| `PROXYSQL_ADMIN_PASS` | Admin password | admin |
| `MONITOR_USER` | Monitor user name | proxysql_monitor |
| `MONITOR_PASS` | Monitor user password | (secure default) |
| `APP_USER` | Application user name | app_user |
| `APP_PASS` | Application user password | (secure default) |
| `DB_NAME` | Default database | postgres |

### Step 1: Run ProxySQL Setup Script

```bash
# Download script
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/8_setup_proxysql_postgresql17.sh /tmp/
chmod +x /tmp/8_setup_proxysql_postgresql17.sh

# Set environment variables
export PRIMARY_HOST="10.41.241.74"
export STANDBY1_HOST="10.41.241.191"
export STANDBY2_HOST="10.41.241.171"
export PG_VERSION="17"
export APP_USER="app_user"
export APP_PASS="YourSecurePassword"
export MONITOR_USER="proxysql_monitor"
export MONITOR_PASS="Monitor_Password_2026!"

# Run script (execute on ProxySQL server)
./8_setup_proxysql_postgresql17.sh
```

### What the Script Configures Automatically

1. **ProxySQL Installation**
   - Downloads ProxySQL 3.0.2 RPM
   - Installs with dependencies
   - Starts ProxySQL service

2. **PostgreSQL User Creation** (on PRIMARY)
   - Creates monitor user for health checks
   - Creates application user
   - Grants appropriate permissions
   - Updates `pg_hba.conf` on all nodes

3. **Backend Server Configuration**
   ```sql
   -- Hostgroup 1: Primary (Read/Write)
   INSERT INTO pgsql_servers VALUES (1, 'PRIMARY_HOST', 5432, 1);

   -- Hostgroup 2: Standbys (Read-Only)
   INSERT INTO pgsql_servers VALUES (2, 'STANDBY1_HOST', 5432, 1);
   INSERT INTO pgsql_servers VALUES (2, 'STANDBY2_HOST', 5432, 1);
   ```

4. **Query Routing Rules**
   ```sql
   -- Route SELECT to standbys (hostgroup 2)
   INSERT INTO pgsql_query_rules VALUES (..., '^SELECT.*', 2);

   -- Route writes to primary (hostgroup 1)
   INSERT INTO pgsql_query_rules VALUES (..., '^INSERT|^UPDATE|^DELETE', 1);
   ```

5. **Connection Pooling**
   - Configures max connections per server
   - Sets connection timeout values
   - Enables connection reuse

### Query Routing Configuration

| Query Type | Destination | Hostgroup |
|------------|-------------|-----------|
| SELECT | Standbys (load balanced) | 2 |
| INSERT/UPDATE/DELETE | Primary | 1 |
| BEGIN/COMMIT/ROLLBACK | Primary | 1 |
| CREATE/DROP/ALTER | Primary | 1 |

### Step 2: Verify ProxySQL Setup

```bash
# Check backend server status
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
SELECT hostgroup_id, hostname, port, status
FROM runtime_pgsql_servers;"

# Check connection pool stats
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, ConnOK, ConnERR
FROM stats_pgsql_connection_pool;"

# Test application connection
PGPASSWORD=YourSecurePassword psql -h 127.0.0.1 -p 6133 -U app_user -d postgres -c "SELECT 1;"
```

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

### Complete Scripts Portfolio

| # | Script | Purpose | Execute On |
|---|--------|---------|------------|
| 1 | `1_PostgreSQL_17_HA_Deployment_Runbook.md` | Deployment documentation | Reference |
| 2 | `2_generate_postgresql_17_ansible.sh` | Generate Ansible playbook for PG17+repmgr | Control Node |
| 3 | `3_pgBackRest_Standby_Backup_Setup_Runbook.md` | Backup configuration documentation | Reference |
| 4 | `4_pgbackrest_standby_backup_setup.sh` | Configure pgBackRest with S3/EBS | STANDBY |
| 5 | `5_pgBackRest_Standby_Restore_Setup_Runbook.md` | Restore documentation | Reference |
| 6 | `6_pgbackrest_standby_setup.sh` | Restore new standby from S3/EBS | NEW STANDBY |
| 7 | `7_pgBackRest_S3_Standby_Restore_Complete_Guide.md` | S3 restore guide | Reference |
| 8 | `8_setup_proxysql_postgresql17.sh` | Configure ProxySQL load balancer | ProxySQL Server |

### Quick Reference: Script Usage

#### Script 2: PostgreSQL 17 HA Cluster Setup
```bash
./2_generate_postgresql_17_ansible.sh \
    --cpu 16 --ram 64 \
    --pg-version 17 \
    --primary-ip 10.41.241.74 \
    --standby-ip 10.41.241.191 \
    --data-dir /dbdata/pgsql/17/data

cd postgresql-repmgr-ansible
ansible-playbook -i inventory.ini site.yml
```

#### Script 4: pgBackRest Backup Setup
```bash
export PRIMARY_IP="10.41.241.74"
export STANDBY_IP="10.41.241.191"
export STORAGE_TYPE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
./4_pgbackrest_standby_backup_setup.sh
```

#### Script 6: Standby Restore from S3
```bash
export RESTORE_SOURCE="s3"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export PRIMARY_IP="10.41.241.74"
export NEW_STANDBY_IP="10.41.241.171"
export NEW_NODE_ID="3"
export NEW_NODE_NAME="standby3"
./6_pgbackrest_standby_setup.sh
```

#### Script 8: ProxySQL Setup
```bash
export PRIMARY_HOST="10.41.241.74"
export STANDBY1_HOST="10.41.241.191"
export STANDBY2_HOST="10.41.241.171"
export APP_USER="app_user"
export APP_PASS="YourSecurePassword"
./8_setup_proxysql_postgresql17.sh
```

### Script Locations in S3

```
s3://btse-stg-pgbackrest-backup/
├── scripts/
│   ├── 2_generate_postgresql_17_ansible.sh
│   ├── 4_pgbackrest_standby_backup_setup.sh
│   ├── 6_pgbackrest_standby_setup.sh
│   └── 8_setup_proxysql_postgresql17.sh
└── docs/
    ├── 1_PostgreSQL_17_HA_Deployment_Runbook.md
    ├── 3_pgBackRest_Standby_Backup_Setup_Runbook.md
    ├── 5_pgBackRest_Standby_Restore_Setup_Runbook.md
    └── 7_pgBackRest_S3_Standby_Restore_Complete_Guide.md
```

### Deployment Workflow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     DEPLOYMENT WORKFLOW                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Step 1: Generate & Run Ansible Playbook                                │
│  ┌─────────────────────────────────────┐                                │
│  │ ./2_generate_postgresql_17_ansible.sh │ ──► Creates Ansible project  │
│  │ ansible-playbook site.yml            │ ──► Deploys PG17 + repmgr    │
│  └─────────────────────────────────────┘                                │
│                    │                                                     │
│                    ▼                                                     │
│  Step 2: Configure pgBackRest Backup (on STANDBY)                       │
│  ┌─────────────────────────────────────┐                                │
│  │ ./4_pgbackrest_standby_backup_setup.sh │ ──► S3/EBS backup setup    │
│  └─────────────────────────────────────┘                                │
│                    │                                                     │
│                    ▼                                                     │
│  Step 3: (Optional) Add New Standby                                     │
│  ┌─────────────────────────────────────┐                                │
│  │ ./6_pgbackrest_standby_setup.sh      │ ──► Restore from S3/EBS      │
│  └─────────────────────────────────────┘                                │
│                    │                                                     │
│                    ▼                                                     │
│  Step 4: Setup ProxySQL Load Balancer                                   │
│  ┌─────────────────────────────────────┐                                │
│  │ ./8_setup_proxysql_postgresql17.sh   │ ──► Read/Write routing       │
│  └─────────────────────────────────────┘                                │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
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

**Document Version**: 2.0
**Last Updated**: 2026-01-19
**Author**: DBA Automation Team

**Change Log**:
- v2.0 (2026-01-19): Updated all phases to reference automation scripts instead of manual commands
- v1.0 (2026-01-17): Initial document with manual deployment steps
