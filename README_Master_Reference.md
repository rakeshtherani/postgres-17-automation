# DBA Automation - Master Reference Guide

## Complete Inventory of Scripts & Documentation

This directory contains a comprehensive collection of PostgreSQL DBA automation scripts, runbooks, and operational documentation for managing high-availability PostgreSQL clusters with repmgr, ProxySQL, and pgBackRest.

**Last Updated**: 2026-01-17
**PostgreSQL Version**: 17.7 (Primary, Standby1, Standby2)
**Environment**: AWS ap-northeast-1 (Tokyo)
**Project Status**: PostgreSQL 17 HA Cluster with S3 Backups and ProxySQL

---

## PostgreSQL 17 HA - Quick Reference

### Server Inventory
| Role | IP Address | Instance ID | Hostname |
|------|------------|-------------|----------|
| Primary | 10.41.241.74 | i-052b680cf24be321e | tyo-aws-stg-binary-option-db-0001 |
| Standby 1 | 10.41.241.191 | i-013fe40421853b6b0 | tyo-aws-stg-binary-option-db-0002 |
| Standby 2 | 10.41.241.171 | i-05c2a08b24488f2ba | tyo-aws-stg-binary-option-db-0003 |

### S3 Bucket Structure
```
s3://btse-stg-pgbackrest-backup/
├── pgbackrest/pg17_cluster/
│   ├── archive/    # WAL archives
│   └── backup/     # Full/incremental backups
├── scripts/        # Automation scripts
└── docs/           # Documentation
```

### Key Scripts for PostgreSQL 17
| Script | Purpose | Download |
|--------|---------|----------|
| `4_pgbackrest_standby_backup_setup.sh` | Setup backups on standby | `aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/4_pgbackrest_standby_backup_setup.sh /tmp/` |
| `6_pgbackrest_standby_setup.sh` | Restore new standby from S3 | `aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/6_pgbackrest_standby_setup.sh /tmp/` |
| `8_setup_proxysql_postgresql17.sh` | Setup ProxySQL load balancer | `aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/8_setup_proxysql_postgresql17.sh /tmp/` |

---

## CRITICAL PREREQUISITES FOR ALL SCRIPTS

### SSH Key Configuration (MUST DO FIRST)

Passwordless SSH must be configured between ALL servers for BOTH `root` and `postgres` users.

#### For ROOT User (on EACH server):
```bash
# Generate SSH key (if not exists)
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# Copy to ALL cluster nodes
ssh-copy-id root@10.41.241.74
ssh-copy-id root@10.41.241.191
ssh-copy-id root@10.41.241.171

# Allow localhost SSH
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Test connections
ssh -o StrictHostKeyChecking=no root@10.41.241.74 hostname
ssh -o StrictHostKeyChecking=no root@10.41.241.191 hostname
ssh -o StrictHostKeyChecking=no root@10.41.241.171 hostname
```

#### For POSTGRES User (on EACH server):
```bash
# Create .ssh directory
sudo mkdir -p /var/lib/pgsql/.ssh
sudo chown postgres:postgres /var/lib/pgsql/.ssh
sudo chmod 700 /var/lib/pgsql/.ssh

# Generate SSH key
sudo -u postgres ssh-keygen -t rsa -b 4096 -N "" -f /var/lib/pgsql/.ssh/id_rsa

# Copy to ALL cluster nodes
sudo -u postgres ssh-copy-id postgres@10.41.241.74
sudo -u postgres ssh-copy-id postgres@10.41.241.191
sudo -u postgres ssh-copy-id postgres@10.41.241.171

# Allow localhost SSH
sudo -u postgres bash -c 'cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys'
sudo chmod 600 /var/lib/pgsql/.ssh/authorized_keys
```

---

## Script 4: pgBackRest Backup Setup (S3)

### Purpose
Sets up pgBackRest backups on a STANDBY server with S3 storage.

### Prerequisites
- PostgreSQL 17 running in recovery mode (standby)
- SSH access from standby to primary (postgres user)
- S3 bucket with IAM role permissions

### Environment Variables
| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `PRIMARY_IP` | 10.41.241.74 | Yes | Primary PostgreSQL server IP |
| `STANDBY_IP` | 10.41.241.191 | Yes | Standby server IP |
| `PG_VERSION` | 17 | Yes | PostgreSQL version |
| `STANZA_NAME` | pg17_cluster | Yes | pgBackRest stanza name |
| `STORAGE_TYPE` | ebs | Yes | `ebs`, `s3`, or `both` |
| `S3_BUCKET` | - | For S3 | S3 bucket name |
| `S3_REGION` | ap-northeast-1 | For S3 | S3 bucket region |

### Usage Example
```bash
# Download from S3
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/4_pgbackrest_standby_backup_setup.sh /tmp/
chmod +x /tmp/4_pgbackrest_standby_backup_setup.sh

# Setup with S3 storage
export STORAGE_TYPE=s3
export S3_BUCKET=btse-stg-pgbackrest-backup
export STANDBY_IP=$(hostname -I | awk '{print $1}')
cd /tmp && ./4_pgbackrest_standby_backup_setup.sh
```

---

## Script 6: Standby Restore from S3

### Purpose
Restores a NEW standby server from S3 backup with pgBackRest.

### Prerequisites
- PostgreSQL 17 installed (but NOT initialized)
- pgBackRest installed
- SSH access to primary server
- S3 bucket with existing backups

### Environment Variables
| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `PRIMARY_IP` | 10.41.241.74 | Yes | Primary PostgreSQL server IP |
| `NEW_STANDBY_IP` | - | Yes | New standby server IP |
| `RESTORE_SOURCE` | ebs | Yes | `ebs` or `s3` |
| `S3_BUCKET` | - | For S3 | S3 bucket name |
| `STANZA_NAME` | pg17_cluster | Yes | pgBackRest stanza name |

### Usage Example
```bash
# Download from S3
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/6_pgbackrest_standby_setup.sh /tmp/
chmod +x /tmp/6_pgbackrest_standby_setup.sh

# Restore from S3
export RESTORE_SOURCE=s3
export S3_BUCKET=btse-stg-pgbackrest-backup
export NEW_STANDBY_IP=$(hostname -I | awk '{print $1}')
export PRIMARY_IP=10.41.241.74
cd /tmp && ./6_pgbackrest_standby_setup.sh
```

---

## Script 8: ProxySQL Setup

### Purpose
Installs and configures ProxySQL 3.0.2 for PostgreSQL 17 with read/write splitting.

### Prerequisites
- SSH access (root) to ALL PostgreSQL servers
- PostgreSQL 17 running on all servers

### Environment Variables
| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `PRIMARY_HOST` | 10.41.241.74 | Yes | Primary PostgreSQL IP |
| `STANDBY1_HOST` | 10.41.241.191 | Yes | Standby 1 IP |
| `STANDBY2_HOST` | 10.41.241.171 | Yes | Standby 2 IP |
| `APP_USER` | app_user | Yes | Application username |
| `APP_PASS` | App_Password_2026! | Yes | Application password |

### Usage Example
```bash
# Download from S3
aws s3 cp s3://btse-stg-pgbackrest-backup/scripts/8_setup_proxysql_postgresql17.sh /tmp/
chmod +x /tmp/8_setup_proxysql_postgresql17.sh

# Execute
cd /tmp && ./8_setup_proxysql_postgresql17.sh
```

### Post-Setup Verification
```bash
# Check admin interface
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c \
  "SELECT hostgroup_id, hostname, port, status FROM runtime_pgsql_servers;"

# Test application connection
PGPASSWORD=App_Password_2026! psql -h 127.0.0.1 -p 6133 -U app_user -d postgres -c "SELECT 1;"
```

---

## Environment Variables Quick Reference

```bash
# PostgreSQL 17 HA Environment Variables
export PRIMARY_IP="10.41.241.74"
export STANDBY1_IP="10.41.241.191"
export STANDBY2_IP="10.41.241.171"
export PG_VERSION="17"
export STANZA_NAME="pg17_cluster"
export CUSTOM_DATA_DIR="/dbdata/pgsql/17/data"
export AWS_REGION="ap-northeast-1"
export S3_BUCKET="btse-stg-pgbackrest-backup"
export S3_REGION="ap-northeast-1"
export STORAGE_TYPE="s3"
export RESTORE_SOURCE="s3"
export PRIMARY_HOST="10.41.241.74"
export STANDBY1_HOST="10.41.241.191"
export STANDBY2_HOST="10.41.241.171"
export APP_USER="app_user"
export APP_PASS="App_Password_2026!"
```

---

## Common Issues and Solutions

### Issue 1: SSH Permission Denied
**Solution:** Use SSM to add SSH keys:
```bash
aws ssm send-command --instance-ids i-TARGETINSTANCE \
  --document-name "AWS-RunShellScript" \
  --parameters commands='["echo YOUR_PUBLIC_KEY >> /root/.ssh/authorized_keys"]' \
  --region ap-northeast-1
```

### Issue 2: S3 Access Denied
**Solution:** Add `repo1-s3-key-type=auto` to pgBackRest config for IAM role authentication.

### Issue 3: Missing Stanza Path
**Solution:** Ensure `repo1-path=/pgbackrest/pg17_cluster` matches S3 structure.

---

## Legacy Documentation (PostgreSQL 13/15)

---

## 📖 Table of Contents

1. [Recommended Reading Order](#-recommended-reading-order)
2. [Documentation Files](#documentation-files)
3. [Ansible Automation (Step 1)](#ansible-automation-step-1)
4. [pgBackREST Scripts (Step 2)](#pgbackrest-scripts-step-2)
5. [ProxySQL Scripts (Step 3)](#proxysql-scripts-step-3)
6. [Quick Reference by Use Case](#quick-reference-by-use-case)
7. [Complete Deployment Order](#complete-deployment-order)

---

## 📚 Recommended Reading Order

> **Start here if you're new to this project.** Follow the numbered sequence below to understand the complete setup from overview to implementation.

### START HERE (Overview)
| # | File | Purpose |
|---|------|---------|
| **1** | `PostgreSQL_HA_Executive_Presentation.md` | Executive summary with theory - **READ FIRST** |
| **2** | `README_Master_Reference.md` | Master index of all files (this file) |

---

### Phase 0: HA Cluster Setup
| # | File | Purpose |
|---|------|---------|
| **3** | `PostgreSQL_HA_Cluster_Complete_Guide.md` | HA cluster operations guide |
| **4** | `Enhanced_PostgreSQL_repmgr_Ansible_Deployment.md` | Ansible deployment docs |
| **5** | `generate_postgresql_ansible.sh` | Script to generate Ansible playbooks |
| **6** | `Failover_testing.md` | Failover test procedures |

---

### Phase 1: Backup Setup (pgBackREST)
| # | File | Purpose |
|---|------|---------|
| **7** | `pgBackREST_Complete_Workflow_Guide.md` | Backup workflow guide |
| **8** | `PGBACKREST_SCRIPTS_DOCUMENTATION.md` | Scripts documentation |
| **9** | `pgbackrest_standby_backup_setup.sh` | Backup automation script |
| **10** | `pgbackrest_standby_setup.sh` | New standby provisioning script |

---

### Phase 2: Logical Replication (pglogical)
| # | File | Purpose |
|---|------|---------|
| **11** | `PostgreSQL_Logical_Replication_Recipes_Guide.md` | 10 replication recipes |
| **12** | `PostgreSQL_pglogical_CrossVersion_Upgrade_Runbook.md` | pglogical upgrade runbook |
| **13** | `Phase2_pglogical_Setup_Complete_Documentation.md` | Actual Phase 2 execution |

---

### Phase 3: PostgreSQL Upgrade
| # | File | Purpose |
|---|------|---------|
| **14** | `PostgreSQL_Logical_Replication_Upgrade_Runbook.md` | Native logical rep runbook |
| **15** | `Phase3_PostgreSQL_15_Upgrade_Progress.md` | Actual Phase 3 execution |

---

### ProxySQL (Load Balancing)
| # | File | Purpose |
|---|------|---------|
| **16** | `PROXYSQL_COMPLETE_GUIDE.md` | ProxySQL guide |
| **17** | `setup_proxysql_postgresql.sh` | Initial setup script |
| **18** | `add_postgresql_to_proxysql.sh` | Add servers script |
| **19** | `configure_proxysql_connection_pooling.sh` | Pooling config script |
| **20** | `monitor_proxysql.sh` | Monitoring script |
| **21** | `verify_proxysql.sh` | Verification script |

---

### Reference / Optional
| # | File | Purpose |
|---|------|---------|
| **22** | `PostgreSQL_Operations_Visual_Guide.md` | Visual diagrams |
| **23** | `TEMP_Phase2_Execution_Log.md` | Execution logs (optional) |

---

### Quick Reading Path Diagram

```
Reading Path:
─────────────

START ──► 1. Executive Presentation (theory + overview)
      │
      └──► 2. Master Reference (index) ◄── YOU ARE HERE
           │
           ├──► 3-6.   Phase 0: HA Cluster Setup
           │
           ├──► 7-10.  Phase 1: Backup (pgBackREST)
           │
           ├──► 11-13. Phase 2: Logical Replication (pglogical)
           │
           ├──► 14-15. Phase 3: PostgreSQL Upgrade
           │
           └──► 16-21. ProxySQL (Load Balancing)
```

---

## 📖 Documentation Files

### 1. PostgreSQL_HA_Cluster_Complete_Guide.md
**Size**: 104 KB
**Purpose**: Main operational guide for PostgreSQL HA cluster

**Contents**:
- Complete cluster architecture and topology
- repmgr configuration and management
- Failover and switchover procedures
- Backup and recovery procedures
- Monitoring and maintenance
- Troubleshooting guide

**When to Use**:
- Setting up new PostgreSQL HA cluster
- Day-to-day cluster operations
- Failover/switchover scenarios
- General cluster troubleshooting

---

### 2. PostgreSQL_Logical_Replication_Recipes_Guide.md
**Size**: 61 KB
**Purpose**: 10 practical recipes for logical replication scenarios

**Contents**:
- Recipe 1: Blue/Green Cluster Migration
- Recipe 2: Table-by-Table Migration
- Recipe 3: Cross-Version Upgrade (PG 10 → 16)
- Recipe 4: Row-Filtered Replication
- Recipe 5: Large-Table Backfill
- Recipe 6: Bidirectional Sync
- Recipe 7: Online Schema Change
- Recipe 8: Cross-Cloud/Cross-Region Move
- Recipe 9: Slice-and-Merge Migration (Sharding)
- Recipe 10: Controlled Decommission

**When to Use**:
- Planning logical replication strategy
- Zero-downtime migrations
- Cross-version upgrades
- IDC → AWS migrations

---

### 3. PostgreSQL_pglogical_CrossVersion_Upgrade_Runbook.md
**Size**: 40 KB
**Purpose**: Step-by-step runbook for upgrading PostgreSQL using pglogical extension

**Contents**:
- Phase 2: Configure pglogical logical replication
- Phase 3: Upgrade PostgreSQL 13 → 15
- Complete troubleshooting guide

**⚠️ Important Note**: This runbook initially planned Option B (cascading via standby3), but PostgreSQL 13 does NOT support logical replication from standbys in recovery mode. See Phase 2 documentation for the implemented solution.

**When to Use**:
- Cross-version upgrade with pglogical
- Reference for pglogical setup

---

### 3a. Phase2_pglogical_Setup_Complete_Documentation.md ⭐ IMPLEMENTED
**Size**: 30 KB
**Purpose**: Actual Phase 2 execution documentation

**Current Implementation (Option A)**:
- Provider: PRIMARY (10.40.0.24, PG 13)
- Subscriber: standby4 (10.40.0.26, PG 13 → 15)

**Contents**:
- Complete pglogical installation steps
- Option A vs Option B analysis
- Why Option B doesn't work in PG 13 (requires PG 16+)
- All errors encountered and solutions
- Live replication testing verified

**When to Use**:
- Setting up pglogical in production
- Understanding cascading replication limitations
- Troubleshooting pglogical issues

---

### 3b. Phase3_PostgreSQL_15_Upgrade_Progress.md ⭐ COMPLETED
**Size**: 13 KB
**Purpose**: PostgreSQL 13 → 15 upgrade execution

**Status**: ✅ COMPLETED (December 30, 2025)

**Contents**:
- 8 detailed execution steps with commands
- pg_upgrade process
- Cross-version replication setup (PG 13 → PG 15)
- 10TB initial sync strategy
- Rollback procedures

**Results Verified**:
- standby4 upgraded to PostgreSQL 15.10
- pglogical replication working: PRIMARY (PG 13) → standby4 (PG 15)
- INSERT/UPDATE/DELETE tested successfully

---

### 4. PostgreSQL_Logical_Replication_Upgrade_Runbook.md
**Size**: 35 KB
**Purpose**: Runbook using native PostgreSQL logical replication

**When to Use**:
- Using native logical replication (not pglogical)
- Simpler setup without extensions

---

### 5. PostgreSQL_Operations_Visual_Guide.md
**Size**: 42 KB
**Purpose**: Visual diagrams and operational flowcharts

**When to Use**:
- Understanding cluster architecture visually
- Training new team members

---

### 6. pgBackREST_Complete_Workflow_Guide.md
**Size**: 55 KB
**Purpose**: Comprehensive pgBackREST automation documentation

**Contents**:
- Analysis of `pgbackrest_standby_backup_setup.sh`
- Analysis of `pgbackrest_standby_setup.sh`
- End-to-end workflows
- Troubleshooting guide

---

### 7. PROXYSQL_COMPLETE_GUIDE.md
**Size**: 18 KB
**Purpose**: Complete ProxySQL deployment and management

**Contents**:
- ProxySQL architecture
- Setup and configuration
- Monitoring and troubleshooting

**Related Scripts**: All 5 ProxySQL scripts

---

### 8. Enhanced_PostgreSQL_repmgr_Ansible_Deployment.md
**Size**: 14 KB
**Purpose**: Ansible-based PostgreSQL cluster deployment documentation

---

### 9. Failover_testing.md
**Size**: 3.8 KB
**Purpose**: Failover testing procedures

---

## 🤖 STEP 1: Ansible Automation (Cluster Deployment)

### 1. generate_postgresql_ansible.sh
**Size**: 155 KB
**Purpose**: Generate Ansible playbooks for PostgreSQL cluster deployment

**Usage**:
```bash
./generate_postgresql_ansible.sh
```

**What it Generates**:
- Complete Ansible inventory
- PostgreSQL installation playbooks
- repmgr configuration playbooks
- ProxySQL setup playbooks
- Monitoring setup

**Output**: Complete Ansible project in `postgresql-repmgr-ansible/` directory

**When to Use**:
- **FIRST STEP** in new cluster deployment
- Automating cluster deployment
- Infrastructure as Code (IaC)
- Consistent multi-cluster deployments

**Timeline**: Generates playbooks in seconds

---

### 2. postgresql-repmgr-ansible/ Directory
**Purpose**: Ansible playbooks and roles for PostgreSQL HA cluster

**Contents**:
```
postgresql-repmgr-ansible/
├── inventory/
│   ├── hosts.ini
│   └── group_vars/
├── playbooks/
│   ├── deploy_postgresql.yml
│   ├── configure_repmgr.yml
│   └── setup_proxysql.yml
├── roles/
│   ├── postgresql/
│   ├── repmgr/
│   └── proxysql/
└── README.md
```

**Usage**:
```bash
cd postgresql-repmgr-ansible/

# Deploy PostgreSQL cluster
ansible-playbook -i inventory/hosts.ini playbooks/deploy_postgresql.yml

# Configure repmgr
ansible-playbook -i inventory/hosts.ini playbooks/configure_repmgr.yml

# Setup ProxySQL
ansible-playbook -i inventory/hosts.ini playbooks/setup_proxysql.yml
```

**When to Use**:
- Automated cluster deployment
- Configuration management
- Repeatable infrastructure setup
- Multi-environment deployments (dev, staging, prod)

**Deployment Order**:
1. Run `generate_postgresql_ansible.sh`
2. Edit inventory files (set IPs, passwords)
3. Deploy PostgreSQL → Configure repmgr → Setup ProxySQL
4. Proceed to STEP 2 (pgBackREST)

---

## 💾 STEP 2: pgBackREST Scripts (Backup Setup)

### 1. pgbackrest_standby_backup_setup.sh
**Size**: 56 KB
**Purpose**: Create backups from standby server with EBS snapshots

**Usage**:
```bash
./pgbackrest_standby_backup_setup.sh \
  --primary-ip 10.40.0.24 \
  --standby-ip 10.40.0.17 \
  --stanza txn_cluster_new \
  --backup-mode auto
```

**Parameters**:
- `--primary-ip`: Primary PostgreSQL server IP (10.40.0.24)
- `--standby-ip`: Standby server to backup from (10.40.0.17)
- `--stanza`: pgBackREST stanza name
- `--backup-mode`: auto, full, incr, skip

**What it Does**:
1. Validates cluster health
2. Configures multi-repository pgBackREST
3. Takes backup from standby (zero impact on primary)
4. Creates EBS snapshots for rapid provisioning
5. Verifies backup integrity
6. Saves state for resume capability

**Key Features**:
- **Multi-repository support**: Different standbys maintain separate backups
- **EBS snapshot integration**: Fast cloning for new standbys
- **Smart resume**: Continues from last checkpoint if interrupted
- **Standby-based backup**: No load on primary server

**Backup Architecture**:
```
Primary (10.40.0.24)
    ↓ Physical Replication
Standby3 (10.40.0.17) [Backup Server]
    ↓ pgBackREST Backup
    ├── Backup Repository: /backup/pgbackrest/repo
    └── EBS Snapshot: snap-xxxxx (for fast provisioning)
```

**When to Use**:
- **SECOND STEP** after Ansible deployment
- Scheduled backups (cron job: daily full, hourly incremental)
- Before major changes (upgrades, migrations)
- Creating base backups for new standbys
- DR backup snapshots

**Cron Example**:
```bash
# Daily full backup at 2 AM
0 2 * * * /path/to/pgbackrest_standby_backup_setup.sh --backup-mode full

# Hourly incremental backup
0 * * * * /path/to/pgbackrest_standby_backup_setup.sh --backup-mode incr
```

**Timeline**: 30 minutes - 2 hours (depends on data size)

---

### 2. pgbackrest_standby_setup.sh
**Size**: 102 KB
**Purpose**: Provision new standby servers from pgBackREST backups or EBS snapshots

**Usage**:
```bash
./pgbackrest_standby_setup.sh \
  --primary-ip 10.40.0.24 \
  --new-standby-ip 10.40.0.26 \
  --snapshot-id snap-0a1b2c3d4e5f6g7h8 \
  --stanza txn_cluster_new
```

**Parameters**:
- `--primary-ip`: Primary PostgreSQL server IP (10.40.0.24)
- `--new-standby-ip`: New standby server IP (e.g., 10.40.0.26)
- `--snapshot-id`: EBS snapshot ID (optional, for fast provisioning)
- `--stanza`: pgBackREST stanza name
- `--repo-num`: Repository number (1-4, default: 1)

**What it Does**:
1. Provisions new EBS volume from snapshot (if using snapshots)
2. Restores PostgreSQL data from pgBackREST
3. Configures streaming replication
4. Sets up recovery settings
5. Registers with repmgr
6. Verifies replication status

**Provisioning Methods**:

**Method A: EBS Snapshot (Fastest)**
```bash
# Use snapshot created by pgbackrest_standby_backup_setup.sh
./pgbackrest_standby_setup.sh \
  --primary-ip 10.40.0.24 \
  --new-standby-ip 10.40.0.26 \
  --snapshot-id snap-0a1b2c3d4e5f6g7h8
```
**Timeline**: 2-4 hours for 2TB database

**Method B: Direct pgBackREST Restore**
```bash
# Restore directly from backup repository
./pgbackrest_standby_setup.sh \
  --primary-ip 10.40.0.24 \
  --new-standby-ip 10.40.0.26 \
  --stanza txn_cluster_new
```
**Timeline**: 4-8 hours for 2TB database

**Key Features**:
- **Smart resume logic**: Skips restore if already on latest backup
- **Automatic configuration**: Sets up all replication parameters
- **Health checks**: Validates cluster state before/after
- **Multi-repository aware**: Can use different backup sources

**When to Use**:
- Adding new standby servers (scale read replicas)
- Replacing failed standbys
- Disaster recovery provisioning
- Testing environments

**Complete Flow**:
```
1. Backup taken by pgbackrest_standby_backup_setup.sh
   ↓
2. EBS snapshot created: snap-xxxxx
   ↓
3. New standby provisioned by pgbackrest_standby_setup.sh
   ↓
4. Standby registered with repmgr
   ↓
5. Proceed to STEP 3 (add to ProxySQL)
```

---

## 🔧 STEP 3: ProxySQL Scripts (Load Balancing)

### 1. setup_proxysql_postgresql.sh
**Size**: 16 KB
**Purpose**: Complete initial ProxySQL installation and configuration

**Usage**:
```bash
./setup_proxysql_postgresql.sh
```

**What it Does**:
1. Installs ProxySQL 3.0.2
2. Configures backend PostgreSQL servers
3. Sets up users and authentication
4. Creates query routing rules
5. Implements connection pooling
6. Configures monitoring

**Configuration**:
```sql
-- Backend servers
Hostgroup 1 (Writes): 10.40.0.24 (Primary)
Hostgroup 2 (Reads): 10.40.0.27, 10.40.0.17 (Standbys)

-- Query routing
Writes (INSERT/UPDATE/DELETE) → Hostgroup 1
Reads (SELECT) → Hostgroup 2
```

**When to Use**:
- **THIRD STEP** after Ansible + pgBackREST
- First-time ProxySQL setup
- Rebuilding ProxySQL from scratch

**Output**: ProxySQL running on `127.0.0.1:6133` (app) and `127.0.0.1:6132` (admin)

**Timeline**: 10-15 minutes

---

### 2. add_postgresql_to_proxysql.sh ⭐ MOST FREQUENTLY USED
**Size**: 6.8 KB
**Purpose**: Add new PostgreSQL backend servers to ProxySQL

**Usage**:
```bash
./add_postgresql_to_proxysql.sh <server_ip> <hostgroup> [weight] [max_connections]

# Examples:
./add_postgresql_to_proxysql.sh 10.40.0.26 2 1000 200    # Add standby to reads
./add_postgresql_to_proxysql.sh 10.40.0.50 1 1000 500    # Add new primary
```

**Parameters**:
- `server_ip`: IP address of PostgreSQL server
- `hostgroup`: 1 (writes/primary), 2 (reads/standbys)
- `weight`: Load balancing weight (default: 1000)
- `max_connections`: Maximum connections (default: 200)

**What it Does**:
1. Tests connectivity to PostgreSQL server
2. Adds server to `pgsql_servers` table
3. Loads configuration to runtime (`LOAD PGSQL SERVERS TO RUNTIME`)
4. Saves to disk (`SAVE PGSQL SERVERS TO DISK`)
5. Verifies addition
6. Tests load balancing

**When to Use**:
- Adding new standbys to read pool (after Step 2 provisioning)
- Adding new primary after migration
- Changing server weights
- Replacing failed servers

**Example Flow**:
```bash
# 1. Provision new standby with pgBackREST
./pgbackrest_standby_setup.sh --new-standby-ip 10.40.0.26

# 2. Add to ProxySQL
./add_postgresql_to_proxysql.sh 10.40.0.26 2 1000 200

# 3. Verify
./verify_proxysql.sh
```

**Timeline**: 2-3 minutes

---

### 3. configure_proxysql_connection_pooling.sh
**Size**: 12 KB
**Purpose**: Advanced connection pooling optimization

**Usage**:
```bash
./configure_proxysql_connection_pooling.sh
```

**What it Does**:
1. Configures pool size limits
2. Sets up connection multiplexing
3. Optimizes connection reuse
4. Configures idle timeouts

**Key Configurations**:
```sql
-- Connection pooling settings
pgsql-max_connections = 1000
pgsql-multiplexing = true
pgsql-connect_timeout_server = 10000
pgsql-connection_max_age_ms = 60000

-- Per-server limits
Primary (10.40.0.24): max_connections = 500
Standbys: max_connections = 200
```

**Problem Solved**:
- Application: 800-900 connections
- ProxySQL pooling → PostgreSQL: 500 connections
- Reduces connection overhead on database

**When to Use**:
- Optimizing connection pool performance
- Handling high connection counts
- After initial ProxySQL setup
- When experiencing connection issues

**Timeline**: 5 minutes

---

### 4. monitor_proxysql.sh
**Size**: 10 KB
**Purpose**: Real-time ProxySQL monitoring

**Usage**:
```bash
./monitor_proxysql.sh                # One-time check
./monitor_proxysql.sh --continuous   # Continuous monitoring
./monitor_proxysql.sh --interval 5   # Custom interval
```

**Monitors**:
- Connection pool status
- Query distribution across backends
- Server load balancing
- Error rates
- Performance metrics

**Output Example**:
```
========================================
ProxySQL Monitoring - 2025-12-19 10:30:45
========================================

CONNECTION POOL STATUS:
┌─────────────┬────────┬──────────┬──────────┬────────┬─────────┐
│ Server      │ HG     │ Status   │ ConnUsed │ ConnFree│ Queries │
├─────────────┼────────┼──────────┼──────────┼────────┼─────────┤
│ 10.40.0.24  │ 1      │ ONLINE   │ 2        │ 8      │ 1250    │
│ 10.40.0.27  │ 2      │ ONLINE   │ 5        │ 15     │ 3420    │
│ 10.40.0.17  │ 2      │ ONLINE   │ 3        │ 17     │ 2180    │
│ 10.40.0.26  │ 2      │ ONLINE   │ 1        │ 19     │ 890     │
└─────────────┴────────┴──────────┴──────────┴────────┴─────────┘

QUERY DISTRIBUTION (Last 60 seconds):
- Writes (HG1): 125 queries → 10.40.0.24 (100%)
- Reads (HG2):  564 queries → Load balanced
  • 10.40.0.27: 312 queries (55.3%)
  • 10.40.0.17: 252 queries (44.7%)

PERFORMANCE METRICS:
- Avg Query Time: 1.2ms
- Connection Pool Hit Rate: 98.5%
- Error Rate: 0.01%
```

**When to Use**:
- Daily health checks
- Troubleshooting performance issues
- Verifying load distribution
- Monitoring during migrations

**Timeline**: Real-time

---

### 5. verify_proxysql.sh
**Size**: 18 KB
**Purpose**: Comprehensive ProxySQL health check and validation

**Usage**:
```bash
./verify_proxysql.sh
```

**Verification Steps**:
1. ProxySQL service status
2. Backend server connectivity
3. Query routing (writes → primary, reads → standbys)
4. Connection pool status
5. User authentication
6. Monitoring setup

**Output Example**:
```
=================================
ProxySQL Verification Report
=================================
[✓] ProxySQL Service: Running
[✓] Admin Interface: Accessible (127.0.0.1:6132)
[✓] App Interface: Accessible (127.0.0.1:6133)

Backend Servers Status:
[✓] Primary (10.40.0.24): ONLINE - 0 errors
[✓] Standby (10.40.0.27): ONLINE - 0 errors
[✓] Standby3 (10.40.0.17): ONLINE - 0 errors
[✓] Standby4 (10.40.0.26): ONLINE - 0 errors

Query Routing:
[✓] Write queries → Primary (10.40.0.24)
[✓] Read queries → Load balanced across standbys

Connection Pool:
- Total Connections: 12
- Used: 4
- Free: 8
- Errors: 0

Overall Status: HEALTHY
```

**When to Use**:
- After ProxySQL configuration changes
- Daily health checks
- Before/after server maintenance
- Troubleshooting connectivity issues

**Timeline**: 2-3 minutes

---

## 🎯 Complete Deployment Order

### New PostgreSQL HA Cluster Setup

```
STEP 1: Ansible Automation (Infrastructure Deployment)
├── 1.1 Run: ./generate_postgresql_ansible.sh
├── 1.2 Edit: inventory files (set IPs, passwords)
├── 1.3 Deploy: ansible-playbook deploy_postgresql.yml
├── 1.4 Configure: ansible-playbook configure_repmgr.yml
└── 1.5 Verify: repmgr cluster show
    Timeline: 1-2 hours

    ↓

STEP 2: pgBackREST (Backup Setup)
├── 2.1 Run: ./pgbackrest_standby_backup_setup.sh (configure)
├── 2.2 Run: First full backup
├── 2.3 Setup: Cron jobs for automated backups
└── 2.4 Verify: pgbackrest --stanza=txn_cluster_new info
    Timeline: 30 minutes - 2 hours (initial backup)

    ↓

STEP 3: ProxySQL (Load Balancing)
├── 3.1 Run: ./setup_proxysql_postgresql.sh
├── 3.2 Add Servers: ./add_postgresql_to_proxysql.sh (for each standby)
├── 3.3 Optimize: ./configure_proxysql_connection_pooling.sh
├── 3.4 Verify: ./verify_proxysql.sh
└── 3.5 Monitor: ./monitor_proxysql.sh --continuous
    Timeline: 15-20 minutes

    ↓

✅ CLUSTER READY FOR PRODUCTION
```

---

## 🚀 Quick Reference by Use Case

### Use Case 1: Complete New Cluster Setup
**Follow STEP 1 → STEP 2 → STEP 3 order above**

Total Timeline: **2-4 hours**

---

### Use Case 2: Add New Standby Server
```bash
# STEP 1: Provision with pgBackREST (STEP 2)
./pgbackrest_standby_setup.sh \
  --primary-ip 10.40.0.24 \
  --new-standby-ip 10.40.0.28 \
  --snapshot-id snap-xxxxx

# STEP 2: Verify repmgr
repmgr cluster show

# STEP 3: Add to ProxySQL (STEP 3)
./add_postgresql_to_proxysql.sh 10.40.0.28 2 1000 200

# STEP 4: Verify
./verify_proxysql.sh
```

Timeline: **2-4 hours** (mostly restore time)

---

### Use Case 3: PostgreSQL Version Upgrade (13 → 15)
```bash
# Use pglogical approach
# Reference: PostgreSQL_pglogical_CrossVersion_Upgrade_Runbook.md

# 1. Ensure standby4 exists (use STEP 2 if needed)
# 2. Follow Phase 2: Setup pglogical
# 3. Follow Phase 3: Upgrade to PG 15
# 4. Already in ProxySQL (STEP 3 done earlier)
```

Timeline: **2-3 hours**

---

### Use Case 4: Daily Operations

**Morning Health Check**:
```bash
./monitor_proxysql.sh
repmgr cluster show
pgbackrest --stanza=txn_cluster_new info
```

**Weekly Verification**:
```bash
./verify_proxysql.sh
```

**Backup Monitoring**:
```bash
# Check last backup
pgbackrest --stanza=txn_cluster_new info

# Manual full backup if needed
./pgbackrest_standby_backup_setup.sh --backup-mode full
```

---

### Use Case 5: Disaster Recovery

**Scenario: Lost standby server**

```bash
# STEP 1: Provision new server with pgBackREST
./pgbackrest_standby_setup.sh \
  --primary-ip 10.40.0.24 \
  --new-standby-ip 10.40.0.XX \
  --snapshot-id snap-latest

# STEP 2: Add to ProxySQL
./add_postgresql_to_proxysql.sh 10.40.0.XX 2 1000 200

# STEP 3: Verify
./verify_proxysql.sh
repmgr cluster show
```

Timeline: **2-4 hours**

---

## 📊 File Size Summary

| Category | Files | Total Size |
|----------|-------|------------|
| **Documentation** | 10 files | ~492 KB |
| **Ansible** | 1 script + directory | ~155 KB |
| **pgBackREST Scripts** | 2 files | ~159 KB |
| **ProxySQL Scripts** | 5 files | ~66 KB |
| **TOTAL** | 18 files + 1 dir | ~872 KB |

---

## 🔗 Script Dependencies

```
Deployment Flow:
================

1. generate_postgresql_ansible.sh
   ↓
2. Ansible Playbooks (postgresql-repmgr-ansible/)
   ↓
3. pgbackrest_standby_backup_setup.sh
   ↓
4. setup_proxysql_postgresql.sh
   ↓
5. add_postgresql_to_proxysql.sh

Ongoing Operations:
==================

Daily:
- monitor_proxysql.sh
- pgbackrest_standby_backup_setup.sh (cron)

Weekly:
- verify_proxysql.sh

As Needed:
- add_postgresql_to_proxysql.sh (new servers)
- pgbackrest_standby_setup.sh (provision standbys)
- configure_proxysql_connection_pooling.sh (optimization)
```

---

## 📞 Current Infrastructure

### Servers
| Server | IP | PostgreSQL | Role | AWS Instance |
|--------|-----|------------|------|--------------|
| **PRIMARY** | 10.40.0.24 | 13.21 | Write operations, pglogical provider | i-0b97d5ff67837092c |
| **Standby** | 10.40.0.27 | 13.21 | Read replica | i-09b6a3782d4866085 |
| **Standby3** | 10.40.0.17 | 13.21 | Read replica + ProxySQL + Backup | i-0b7fc7c40f824a8b9 |
| **Standby4** | 10.40.0.26 | **15.10** | pglogical subscriber (upgraded) | i-0962ac642dd1cfe7b |

### Services
- **ProxySQL**: 10.40.0.17:6133 (app), :6132 (admin)
- **repmgr**: Cluster management (PRIMARY, Standby, Standby3)
- **pgBackREST**: Backup repository on 10.40.0.17
- **pglogical**: Cross-version replication PRIMARY → Standby4

### Replication Architecture
```
PRIMARY (PostgreSQL 13.21)
    ├─ Physical Streaming → Standby (PG 13) [HA failover candidate]
    ├─ Physical Streaming → Standby3 (PG 13) [HA + Backup server]
    └─ pglogical Logical → Standby4 (PG 15.10) [Upgrade testing] ✅
```

**Note**: Option B (cascading via Standby3) not possible in PG 13. Requires PostgreSQL 16+ for logical replication from standbys in recovery mode.

---

## 🎯 Most Frequently Used Scripts

1. ✅ `add_postgresql_to_proxysql.sh` - Adding servers to ProxySQL
2. ✅ `monitor_proxysql.sh` - Daily monitoring
3. ✅ `verify_proxysql.sh` - Health checks
4. ✅ `pgbackrest_standby_setup.sh` - Provisioning new standbys
5. ✅ `pgbackrest_standby_backup_setup.sh` - Scheduled backups (cron)

---

## 📖 Documentation Priority

**Start Here** (New DBAs):
1. `PostgreSQL_HA_Cluster_Complete_Guide.md` - Overview
2. This file (`README_Master_Reference.md`) - Script reference
3. `PostgreSQL_Operations_Visual_Guide.md` - Visual diagrams

**For Specific Tasks**:
- **Deployment**: Ansible documentation
- **Backups**: `pgBackREST_Complete_Workflow_Guide.md`
- **Load Balancing**: `PROXYSQL_COMPLETE_GUIDE.md`
- **Upgrades**: `PostgreSQL_pglogical_CrossVersion_Upgrade_Runbook.md`

---

## 🔄 Version History

**2025-12-30** (Latest):
- ✅ **Phase 3 COMPLETED**: PostgreSQL 13 → 15 upgrade on standby4
- ✅ Cross-version replication verified (PG 13 → PG 15)
- Added `Phase3_PostgreSQL_15_Upgrade_Progress.md` (completed)
- Updated master reference with correct architecture
- Documented 10TB initial sync strategy

**2025-12-29**:
- ✅ **Phase 2 COMPLETED**: pglogical setup
- Added `Phase2_pglogical_Setup_Complete_Documentation.md`
- Documented Option A vs Option B (Option B requires PG 16+)
- Live replication testing completed

**2025-12-20**:
- Added `PostgreSQL_pglogical_CrossVersion_Upgrade_Runbook.md` (initial plan)

**2025-12-19**:
- Created `pgBackREST_Complete_Workflow_Guide.md`
- Set up backup automation on standby3

**2025-12-15**:
- Created `PostgreSQL_HA_Cluster_Complete_Guide.md`
- Initial HA cluster setup completed

**Current Versions**:
- PostgreSQL: 13.21 (PRIMARY, Standby, Standby3), **15.10** (Standby4)
- repmgr: 5.3.3
- ProxySQL: 3.0.2
- pglogical: 2.4.6
- OS: Amazon Linux 2023

---

## 📋 Project Phases Summary

| Phase | Description | Status | Documentation |
|-------|-------------|--------|---------------|
| Phase 0 | Ansible HA Cluster Deployment | ✅ Complete | PostgreSQL_HA_Cluster_Complete_Guide.md |
| Phase 1 | pgBackREST Backup Setup | ✅ Complete | pgBackREST_Complete_Workflow_Guide.md |
| Phase 2 | pglogical Logical Replication | ✅ Complete | Phase2_pglogical_Setup_Complete_Documentation.md |
| Phase 3 | PostgreSQL 15 Upgrade | ✅ Complete | Phase3_PostgreSQL_15_Upgrade_Progress.md |
| Phase 4 | Production Rollout | 📋 Planned | Use Phase 2 & 3 docs for 10TB production |

---

**Document**: Master Reference Guide
**Version**: 2.0
**Created**: 2025-12-19
**Last Updated**: 2025-12-30
**Location**: `/Users/rakeshtherani/Downloads/dba-automation/README_Master_Reference.md`
