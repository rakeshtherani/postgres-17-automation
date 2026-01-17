# PostgreSQL 17 High Availability Cluster Deployment Runbook
## Streaming Replication with repmgr on Amazon Linux 2023

---

## Document Information

| Field | Value |
|-------|-------|
| Document Version | 1.0 |
| Last Updated | 2026-01-13 |
| PostgreSQL Version | 17.7 |
| repmgr Version | 5.5.0 |
| Target OS | Amazon Linux 2023 |
| Deployment Method | Ansible Automation |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Prerequisites and Requirements](#3-prerequisites-and-requirements)
4. [Pre-Deployment Checklist](#4-pre-deployment-checklist)
5. [Deployment Procedure](#5-deployment-procedure)
6. [Post-Deployment Verification](#6-post-deployment-verification)
7. [Configuration Details](#7-configuration-details)
8. [Operations Procedures](#8-operations-procedures)
9. [Troubleshooting Guide](#9-troubleshooting-guide)
10. [Rollback Procedure](#10-rollback-procedure)
11. [Appendix](#11-appendix)

---

## 1. Executive Summary

### Purpose
This runbook provides step-by-step instructions for deploying a PostgreSQL 17 High Availability cluster using streaming replication managed by repmgr 5.5.0.

### Scope
- Fresh installation of PostgreSQL 17 on Amazon Linux 2023
- Configuration of primary-standby replication
- Setup of repmgr for replication management
- Manual failover capability (no automatic failover)

### Key Components

| Component | Version | Purpose |
|-----------|---------|---------|
| PostgreSQL | 17.7 | Primary database engine |
| repmgr | 5.5.0 | Replication management and monitoring |
| Ansible | 2.15+ | Deployment automation |

---

## 2. Architecture Overview

### 2.1 Cluster Topology

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PostgreSQL HA Cluster                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│    ┌──────────────────────┐              ┌──────────────────────┐           │
│    │      PRIMARY         │              │       STANDBY        │           │
│    │                      │   Streaming  │                      │           │
│    │  tyo-aws-stg-binary  │  Replication │  tyo-aws-stg-binary  │           │
│    │  -option-db-0001     │ ──────────── │  -option-db-0002     │           │
│    │                      │  (Async)     │                      │           │
│    │  IP: 10.41.241.74    │              │  IP: 10.41.241.191   │           │
│    │                      │              │                      │           │
│    │  ┌────────────────┐  │              │  ┌────────────────┐  │           │
│    │  │ PostgreSQL 17  │  │              │  │ PostgreSQL 17  │  │           │
│    │  │ (Read/Write)   │  │              │  │ (Read Only)    │  │           │
│    │  └────────────────┘  │              │  └────────────────┘  │           │
│    │                      │              │                      │           │
│    │  ┌────────────────┐  │              │  ┌────────────────┐  │           │
│    │  │ repmgr 5.5.0   │  │              │  │ repmgr 5.5.0   │  │           │
│    │  │ (Node ID: 1)   │  │              │  │ (Node ID: 2)   │  │           │
│    │  └────────────────┘  │              │  └────────────────┘  │           │
│    │                      │              │                      │           │
│    └──────────────────────┘              └──────────────────────┘           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

                    Replication Slot: standby_slot (physical)
```

### 2.2 Server Details

| Attribute | Primary | Standby |
|-----------|---------|---------|
| Hostname | tyo-aws-stg-binary-option-db-0001 | tyo-aws-stg-binary-option-db-0002 |
| IP Address | 10.41.241.74 | 10.41.241.191 |
| AWS Instance ID | i-052b680cf24be321e | i-013fe40421853b6b0 |
| Role | Read/Write | Hot Standby (Read Only) |
| repmgr Node ID | 1 | 2 |

### 2.3 Data Flow

```
Client Application
        │
        ▼
┌───────────────┐
│    PRIMARY    │
│  PostgreSQL   │
│   (R/W)       │
└───────┬───────┘
        │
        │ WAL Streaming (Async)
        │ via Replication Slot
        ▼
┌───────────────┐
│    STANDBY    │
│  PostgreSQL   │
│   (R/O)       │
└───────────────┘
```

---

## 3. Prerequisites and Requirements

### 3.1 Hardware Requirements

| Resource | Minimum | Recommended | Current Setup |
|----------|---------|-------------|---------------|
| CPU Cores | 2 | 4+ | 4 |
| RAM | 8 GB | 16+ GB | 15 GB |
| Storage | 50 GB | 100+ GB SSD | SSD |
| Network | 1 Gbps | 10 Gbps | AWS VPC |

### 3.2 Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| Amazon Linux | 2023 | Operating System |
| Python | 3.9+ | Ansible dependency |
| Ansible | 2.15+ | Automation |
| AWS CLI | 2.x | S3 access for script |

### 3.3 Network Requirements

| Port | Protocol | Source | Destination | Purpose |
|------|----------|--------|-------------|---------|
| 22 | TCP | All nodes | All nodes | SSH (postgres user) |
| 5432 | TCP | All nodes | All nodes | PostgreSQL |
| 5432 | TCP | Application | Primary | Client connections |

### 3.4 Account Requirements

| Account | Purpose | Permissions |
|---------|---------|-------------|
| root | Ansible execution | Full system access |
| postgres | PostgreSQL service | Database owner |
| repmgr | Replication management | SUPERUSER, REPLICATION |

---

## 4. Pre-Deployment Checklist

### 4.1 Server Preparation

- [ ] Both servers are running Amazon Linux 2023
- [ ] Root SSH access is available to both servers
- [ ] Data directory mount point exists: `/dbdata/pgsql/17/data`
- [ ] Sufficient disk space (minimum 50GB free)
- [ ] Network connectivity between nodes verified

### 4.2 Network Verification

```bash
# From Primary, test connectivity to Standby
ping -c 3 10.41.241.191

# From Standby, test connectivity to Primary
ping -c 3 10.41.241.74

# Verify port 5432 is not blocked (run after deployment)
nc -zv 10.41.241.191 5432
```

### 4.3 Cleanup (If Re-deploying)

```bash
# Run on BOTH servers
pkill -9 postgres
sleep 2
rm -rf /dbdata/pgsql/17/data/*
rm -rf /var/lib/pgsql/repmgr.conf
rm -rf /home/postgres/.ssh
rm -rf /root/postgresql-repmgr-ansible
rm -rf /tmp/postgresql-repmgr-ansible
```

---

## 5. Deployment Procedure

### 5.1 Overview of Deployment Steps

| Step | Action | Duration |
|------|--------|----------|
| 1 | Download generator script | ~10 sec |
| 2 | Generate Ansible project | ~5 sec |
| 3 | Generate inventory | ~5 sec |
| 4 | Execute deployment | ~3-5 min |
| 5 | Verify deployment | ~1 min |

### 5.2 Step 1: Download Generator Script

**Execute on PRIMARY server (10.41.241.74)**

```bash
# Navigate to temporary directory
cd /tmp

# Download the generator script from S3
aws s3 cp s3://btse-stg-pgbackrest-backup/generate_postgresql_17_ansible.sh .

# Make it executable
chmod +x generate_postgresql_17_ansible.sh
```

**Verification:**
```bash
ls -la generate_postgresql_17_ansible.sh
# Expected: -rwxr-xr-x 1 root root ... generate_postgresql_17_ansible.sh
```

### 5.3 Step 2: Generate Ansible Project

**Execute on PRIMARY server**

```bash
./generate_postgresql_17_ansible.sh \
  -c 4 \
  -r 15 \
  -p 17 \
  --primary-ip 10.41.241.74 \
  --standby-ip 10.41.241.191 \
  -s ssd \
  -d /dbdata/pgsql/17/data
```

**Command Parameters Explained:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `-c 4` | 4 | Number of CPU cores |
| `-r 15` | 15 | RAM in GB |
| `-p 17` | 17 | PostgreSQL version |
| `--primary-ip` | 10.41.241.74 | Primary server IP |
| `--standby-ip` | 10.41.241.191 | Standby server IP |
| `-s ssd` | ssd | Storage type (ssd/hdd) |
| `-d` | /dbdata/pgsql/17/data | PostgreSQL data directory |

**Expected Output:**
```
Enhanced PostgreSQL + repmgr Ansible Project Setup
Configuration:
  CPU Cores: 4
  RAM (GB): 15
  PostgreSQL Version: 17
  repmgr Version: 5.5.0
  Storage Type: ssd
  Primary IP: 10.41.241.74
  Standby IP: 10.41.241.191
  Data Directory: /dbdata/pgsql/17/data
  Install PostgreSQL: true

Creating directory structure...
Creating configuration files...
Creating main playbooks...
Creating role files...
Creating repmgr primary templates...
Creating repmgr standby templates...
Enhanced PostgreSQL + repmgr Ansible Project Created Successfully!
...
Enhanced project ready in: /tmp/postgresql-repmgr-ansible
```

### 5.4 Step 3: Generate Inventory

**Execute on PRIMARY server**

```bash
# Change to project directory
cd /tmp/postgresql-repmgr-ansible

# Generate inventory from configuration
ansible-playbook generate_inventory.yml
```

**Expected Output:**
```
PLAY [Generate PostgreSQL + repmgr Inventory from Config] ***

TASK [Display configuration summary] ***
ok: [localhost] => {
    "msg": [
        "PostgreSQL Version: 17",
        "repmgr Version: 5.5.0",
        "CPU Cores: 4",
        "RAM: 15GB",
        "Storage Type: ssd",
        "Primary IP: 10.41.241.74",
        "Standby IP: 10.41.241.191",
        ...
    ]
}

TASK [Create inventory directory] ***
ok: [localhost]

TASK [Generate inventory file] ***
changed: [localhost]
...

PLAY RECAP ***
localhost  : ok=6  changed=2  unreachable=0  failed=0  skipped=0  rescued=0  ignored=0
```

### 5.5 Step 4: Execute Deployment

**Execute on PRIMARY server**

```bash
ansible-playbook -i inventory/hosts.yml site.yml
```

**Deployment Phases:**

| Phase | Play | Description |
|-------|------|-------------|
| 1 | OS Tuning & PostgreSQL | Install packages, configure PostgreSQL on ALL nodes |
| 2 | Primary Configuration | Register primary node with repmgr |
| 3 | Standby Configuration | Clone from primary, configure as standby |
| 4 | Final Verification | Test replication, show cluster status |

**Expected Duration:** 3-5 minutes

**Expected Final Output:**
```
PLAY RECAP ***
tyo-aws-stg-binary-option-db-0001 : ok=135  changed=31  unreachable=0  failed=0  skipped=45  rescued=0  ignored=0
tyo-aws-stg-binary-option-db-0002 : ok=150  changed=36  unreachable=0  failed=0  skipped=47  rescued=2  ignored=0
```

**Note:** `rescued=2` on standby is expected behavior - the systemd service falls back to pg_ctl.

---

## 6. Post-Deployment Verification

### 6.1 Check Cluster Status

**Run on any node:**
```bash
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf cluster show
```

**Expected Output:**
```
 ID | Name    | Role    | Status    | Upstream | Location | Priority | Timeline | Connection string
----+---------+---------+-----------+----------+----------+----------+----------+---------------------------------------------------------------
 1  | primary | primary | * running |          | default  | 100      | 1        | host=10.41.241.74 user=repmgr dbname=repmgr connect_timeout=2
 2  | standby | standby |   running | primary  | default  | 100      | 1        | host=10.41.241.191 user=repmgr dbname=repmgr connect_timeout=2
```

### 6.2 Verify Replication Status

**On PRIMARY (10.41.241.74):**
```bash
sudo -u postgres psql -c "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"
```

**Expected Output:**
```
  client_addr   |   state   |  sent_lsn   | write_lsn  | flush_lsn  | replay_lsn
----------------+-----------+-------------+------------+------------+------------
 10.41.241.191  | streaming | 0/3000178   | 0/3000178  | 0/3000178  | 0/3000178
```

**On STANDBY (10.41.241.191):**
```bash
# Check recovery mode
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

# Expected: t (true)

# Check WAL receiver
sudo -u postgres psql -c "SELECT pid, status, sender_host, slot_name FROM pg_stat_wal_receiver;"
```

**Expected Output:**
```
  pid   |  status   | sender_host  |  slot_name
--------+-----------+--------------+--------------
 144394 | streaming | 10.41.241.74 | standby_slot
```

### 6.3 Test Replication

**On PRIMARY:**
```bash
sudo -u postgres psql -c "CREATE TABLE replication_test (id serial, data text, created_at timestamp default now());"
sudo -u postgres psql -c "INSERT INTO replication_test (data) VALUES ('test_data');"
```

**On STANDBY (wait 2-3 seconds):**
```bash
sudo -u postgres psql -c "SELECT * FROM replication_test;"
```

**Cleanup (on PRIMARY):**
```bash
sudo -u postgres psql -c "DROP TABLE replication_test;"
```

### 6.4 Cluster Health Check

```bash
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf cluster crosscheck
```

**Expected Output:**
```
 Name    | ID | 1 | 2
---------+----+---+---
 primary | 1  | * | *
 standby | 2  | * | *
```
All `*` indicates healthy connections between all nodes.

---

## 7. Configuration Details

### 7.1 PostgreSQL Memory Configuration (15GB RAM)

| Parameter | Value | Calculation |
|-----------|-------|-------------|
| shared_buffers | 3840 MB | ~25% of RAM |
| effective_cache_size | 11520 MB | ~75% of RAM |
| work_mem | 157 MB | RAM / (max_connections * 2) |
| maintenance_work_mem | 960 MB | ~6% of RAM |
| wal_buffers | 120 MB | Auto-tuned |

### 7.2 Replication Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| wal_level | replica | Required for replication |
| max_wal_senders | 10 | Maximum replication connections |
| max_replication_slots | 10 | Maximum replication slots |
| synchronous_commit | off | Async replication (better performance) |
| hot_standby | on | Allow read queries on standby |

### 7.3 Key File Locations

| File | Path |
|------|------|
| PostgreSQL Data | /dbdata/pgsql/17/data |
| PostgreSQL Config | /dbdata/pgsql/17/data/postgresql.conf |
| pg_hba.conf | /dbdata/pgsql/17/data/pg_hba.conf |
| PostgreSQL Log | /dbdata/pgsql/17/data/log/postgresql-*.log |
| repmgr Config | /var/lib/pgsql/repmgr.conf |
| repmgr Log | /var/log/repmgr/repmgr.log |

### 7.4 repmgr Configuration

```ini
node_id=1                          # 1 for primary, 2 for standby
node_name='primary'                # or 'standby'
conninfo='host=10.41.241.74 user=repmgr dbname=repmgr connect_timeout=2'
data_directory='/dbdata/pgsql/17/data'
use_replication_slots=yes
monitoring_history=yes
log_file='/var/log/repmgr/repmgr.log'
pg_bindir='/usr/pgsql-17/bin'      # PGDG default path
```

---

## 8. Operations Procedures

### 8.1 Manual Failover (Emergency)

**Scenario:** Primary server has failed and is unrecoverable.

**On STANDBY server:**
```bash
# Promote standby to primary
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby promote
```

**Verification:**
```bash
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf cluster show
```

### 8.2 Planned Switchover (Zero Downtime)

**Scenario:** Maintenance on primary, switch roles with standby.

**On STANDBY server:**
```bash
# Perform switchover
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby switchover
```

This will:
1. Verify both nodes are healthy
2. Pause replication
3. Promote standby to primary
4. Demote old primary to standby
5. Resume replication in reverse direction

### 8.3 Rejoin Failed Node

**Scenario:** After failover, rejoin the old primary as a new standby.

**On the FAILED node (old primary):**
```bash
# 1. Stop PostgreSQL if running
sudo -u postgres pg_ctl stop -D /dbdata/pgsql/17/data -m fast 2>/dev/null || true
pkill -9 postgres 2>/dev/null || true

# 2. Clone from new primary
sudo -u postgres repmgr -h <NEW_PRIMARY_IP> -U repmgr \
  -f /var/lib/pgsql/repmgr.conf standby clone --force

# 3. Start PostgreSQL
sudo -u postgres pg_ctl start -D /dbdata/pgsql/17/data \
  -l /dbdata/pgsql/17/data/log/postgresql.log

# 4. Register as standby
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby register --force
```

### 8.4 Start/Stop PostgreSQL

**Using pg_ctl (Recommended for Amazon Linux 2023):**
```bash
# Start
sudo -u postgres pg_ctl start -D /dbdata/pgsql/17/data \
  -l /dbdata/pgsql/17/data/log/postgresql.log

# Stop (fast mode)
sudo -u postgres pg_ctl stop -D /dbdata/pgsql/17/data -m fast

# Reload configuration
sudo -u postgres pg_ctl reload -D /dbdata/pgsql/17/data

# Check status
sudo -u postgres pg_ctl status -D /dbdata/pgsql/17/data
```

### 8.5 Check Replication Lag

**On STANDBY:**
```bash
sudo -u postgres psql -c "
SELECT
  now() - pg_last_xact_replay_timestamp() AS replication_lag,
  pg_last_wal_receive_lsn() AS received_lsn,
  pg_last_wal_replay_lsn() AS replayed_lsn;
"
```

---

## 9. Troubleshooting Guide

### 9.1 PostgreSQL Won't Start

**Check logs:**
```bash
tail -100 /dbdata/pgsql/17/data/log/postgresql-*.log
```

**Common causes:**
1. Port already in use
2. Data directory permissions
3. Configuration syntax error

**Solutions:**
```bash
# Check if port is in use
ss -tlnp | grep 5432

# Kill existing postgres processes
pkill -9 postgres

# Fix permissions
chown -R postgres:postgres /dbdata/pgsql/17/data
chmod 700 /dbdata/pgsql/17/data

# Verify config syntax
sudo -u postgres /usr/bin/postgres -D /dbdata/pgsql/17/data -C config_file
```

### 9.2 Replication Not Working

**Check on PRIMARY:**
```bash
# Check replication connections
sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;"

# Check replication slots
sudo -u postgres psql -c "SELECT * FROM pg_replication_slots;"

# Check pg_hba.conf allows replication
grep replication /dbdata/pgsql/17/data/pg_hba.conf
```

**Check on STANDBY:**
```bash
# Check WAL receiver
sudo -u postgres psql -c "SELECT * FROM pg_stat_wal_receiver;"

# Check postgresql.auto.conf
cat /dbdata/pgsql/17/data/postgresql.auto.conf

# Check standby.signal exists
ls -la /dbdata/pgsql/17/data/standby.signal
```

### 9.3 SSH Connectivity Issues

```bash
# Test SSH as postgres user
sudo -u postgres ssh -o StrictHostKeyChecking=no postgres@<OTHER_NODE_IP> hostname

# If fails, regenerate SSH keys
sudo -u postgres ssh-keygen -t rsa -b 4096 -f /home/postgres/.ssh/id_rsa -N ""

# Copy key to other node
sudo -u postgres ssh-copy-id -i /home/postgres/.ssh/id_rsa.pub postgres@<OTHER_NODE_IP>
```

### 9.4 repmgr Command Fails

```bash
# Check repmgr config
cat /var/lib/pgsql/repmgr.conf

# Test repmgr connectivity
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf node check

# Check repmgr extension
sudo -u postgres psql -d repmgr -c "\dx repmgr"
```

---

## 10. Rollback Procedure

### 10.1 Complete Rollback (Remove Installation)

**Execute on BOTH servers:**
```bash
# Stop PostgreSQL
pkill -9 postgres
sleep 2

# Remove data
rm -rf /dbdata/pgsql/17/data/*

# Remove repmgr config
rm -f /var/lib/pgsql/repmgr.conf

# Remove SSH keys
rm -rf /home/postgres/.ssh

# Remove Ansible project
rm -rf /tmp/postgresql-repmgr-ansible
rm -rf /root/postgresql-repmgr-ansible

# Optionally, remove PostgreSQL packages
# dnf remove postgresql17* -y
```

### 10.2 Re-deploy After Rollback

Follow deployment steps from [Section 5](#5-deployment-procedure).

---

## 11. Appendix

### 11.1 Quick Reference Commands

| Task | Command |
|------|---------|
| Cluster status | `sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf cluster show` |
| Node status | `sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf node status` |
| Cluster health | `sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf cluster crosscheck` |
| Promote standby | `sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby promote` |
| Switchover | `sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby switchover` |
| Clone standby | `sudo -u postgres repmgr -h <PRIMARY_IP> -U repmgr -f /var/lib/pgsql/repmgr.conf standby clone --force` |
| Register standby | `sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby register --force` |
| Start PostgreSQL | `sudo -u postgres pg_ctl start -D /dbdata/pgsql/17/data -l /dbdata/pgsql/17/data/log/postgresql.log` |
| Stop PostgreSQL | `sudo -u postgres pg_ctl stop -D /dbdata/pgsql/17/data -m fast` |
| Reload config | `sudo -u postgres pg_ctl reload -D /dbdata/pgsql/17/data` |

### 11.2 Important File Locations

| Description | Path |
|-------------|------|
| PostgreSQL Data | `/dbdata/pgsql/17/data` |
| PostgreSQL Config | `/dbdata/pgsql/17/data/postgresql.conf` |
| PostgreSQL Auth | `/dbdata/pgsql/17/data/pg_hba.conf` |
| PostgreSQL Logs | `/dbdata/pgsql/17/data/log/` |
| repmgr Config | `/var/lib/pgsql/repmgr.conf` |
| repmgr Logs | `/var/log/repmgr/repmgr.log` |
| Ansible Project | `/tmp/postgresql-repmgr-ansible/` |
| Generator Script | `/tmp/generate_postgresql_17_ansible.sh` |

### 11.3 Deployment Script Location

```
S3: s3://btse-stg-pgbackrest-backup/generate_postgresql_17_ansible.sh
```

### 11.4 Contact Information

| Role | Contact |
|------|---------|
| DBA Team | [Your DBA Team Contact] |
| On-Call | [On-Call Contact] |

---

## 12. Complete Ansible Deployment Output Log

This section contains the complete output from a successful deployment for reference.

### 12.1 Step 1: Generate Ansible Project

```bash
[root@tyo-aws-stg-binary-option-db-0001 tmp]# ./generate_postgresql_ansible.sh -c 4 -r 15 -p 17 --primary-ip 10.41.241.74 --standby-ip 10.41.241.191 -s ssd -d /dbdata/pgsql/17/data
Enhanced PostgreSQL + repmgr Ansible Project Setup
Configuration:
  CPU Cores: 4
  RAM (GB): 15
  PostgreSQL Version: 17
  repmgr Version: 5.5.0
  Storage Type: ssd
  Primary IP: 10.41.241.74
  Standby IP: 10.41.241.191
  Data Directory: /dbdata/pgsql/17/data
  Install PostgreSQL: true

Creating directory structure...
Creating configuration files...
Creating main playbooks...
Creating role files...
Creating repmgr primary templates...
Creating repmgr standby templates...
Enhanced PostgreSQL + repmgr Ansible Project Created Successfully!
Configuration Summary:
  Hardware: 4 CPU cores, 15GB RAM
  Storage: SSD
  PostgreSQL: v17
  repmgr: v5.5.0
  Primary: 10.41.241.74
  Standby: 10.41.241.191

Memory Configuration:
  Shared Buffers: 3840MB
  Effective Cache: 11520MB
  Work Memory: 157286kB
  Maintenance Work Memory: 960MB

OS Tuning:
  Hugepages: 2944 pages
  Shared Memory Max: 7GB
  THP: Disabled

Next Steps:
1. Review and customize config.yml
2. Generate inventory: ansible-playbook generate_inventory.yml
3. Check system info: ansible-playbook -i inventory/hosts.yml playbooks/system_info.yml
4. Deploy cluster: ansible-playbook -i inventory/hosts.yml site.yml
5. Verify performance: ansible-playbook -i inventory/hosts.yml playbooks/performance_verification.yml

To Add Additional Standby Servers:
• Interactive mode: ansible-playbook add_standby.yml
• Command line: ansible-playbook add_standby.yml -e "new_standby_ip=10.40.0.28 new_standby_hostname=standby-003 node_id=3"
• Then configure: ansible-playbook -i inventory/hosts.yml configure_new_standby.yml -e "target_host=standby-003"

Enhanced project ready in: /tmp/postgresql-repmgr-ansible
```

### 12.2 Step 2: Generate Inventory

```bash
[root@tyo-aws-stg-binary-option-db-0001 tmp]# cd postgresql-repmgr-ansible/
[root@tyo-aws-stg-binary-option-db-0001 postgresql-repmgr-ansible]# ansible-playbook generate_inventory.yml
[WARNING]: Unable to parse /tmp/postgresql-repmgr-ansible/inventory/hosts.yml as an inventory source
[WARNING]: No inventory was parsed, only implicit localhost is available
[WARNING]: provided hosts list is empty, only localhost is available.

PLAY [Generate PostgreSQL + repmgr Inventory from Config]

TASK [Display configuration summary]
ok: [localhost] => {
    "msg": [
        "PostgreSQL Version: 17",
        "repmgr Version: 5.5.0",
        "CPU Cores: 4",
        "RAM: 15GB",
        "Storage Type: ssd",
        "Primary IP: 10.41.241.74",
        "Standby IP: 10.41.241.191",
        "Performance Profile: auto",
        "Environment: production",
        "Shared Buffers: 3840MB",
        "Effective Cache Size: 11520MB",
        "SSL Enabled: False",
        "Monitoring Enabled: True",
        "Backup Enabled: True"
    ]
}

TASK [Create inventory directory]
ok: [localhost]

TASK [Generate inventory file]
changed: [localhost]

TASK [Create group_vars directory]
ok: [localhost]

TASK [Generate group variables]
changed: [localhost]

TASK [Display next steps]
ok: [localhost] => {
    "msg": [
        "Inventory and configuration generated successfully!",
        "",
        "Next steps:",
        "1. Review and customize config.yml if needed",
        "2. Update SSH key path in config.yml",
        "3. Deploy the cluster: ansible-playbook -i inventory/hosts.yml site.yml",
        "",
        "Testing commands:",
        "- Test replication: ansible-playbook -i inventory/hosts.yml playbooks/test_replication.yml",
        "- Check cluster status: ansible-playbook -i inventory/hosts.yml playbooks/cluster_status.yml",
        "- Manual failover guide: ansible-playbook -i inventory/hosts.yml playbooks/setup_manual_failover_guide.yml"
    ]
}

PLAY RECAP
localhost                  : ok=6    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

### 12.3 Step 3: Deploy Cluster (Complete Output)

```bash
[root@tyo-aws-stg-binary-option-db-0001 postgresql-repmgr-ansible]# ansible-playbook -i inventory/hosts.yml site.yml
[WARNING]: Collection community.crypto does not support Ansible version 2.15.3

PLAY [Apply OS tuning and deploy PostgreSQL cluster with repmgr]

TASK [Gathering Facts]
ok: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [Validate configuration]
included: /tmp/postgresql-repmgr-ansible/playbooks/validate_config.yml for tyo-aws-stg-binary-option-db-0001

TASK [Validate PostgreSQL configuration]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "changed": false,
    "msg": "All assertions passed"
}

TASK [Check if servers are reachable]
ok: [tyo-aws-stg-binary-option-db-0001 -> localhost] => (item=10.41.241.74)
ok: [tyo-aws-stg-binary-option-db-0001 -> localhost] => (item=10.41.241.191)

TASK [os_tuning : Install system packages (skip curl to avoid conflicts)]
ok: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [common : Install system packages (skip curl to avoid conflicts)]
ok: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [common : Create postgres user]
ok: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [common : Get postgres user info]
ok: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [common : Create SSH directory for postgres user]
ok: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [common : Generate SSH key for postgres user]
ok: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [common : Exchange SSH keys between postgres users]
ok: [tyo-aws-stg-binary-option-db-0001] => (item=tyo-aws-stg-binary-option-db-0001)
ok: [tyo-aws-stg-binary-option-db-0002] => (item=tyo-aws-stg-binary-option-db-0001)
ok: [tyo-aws-stg-binary-option-db-0001] => (item=tyo-aws-stg-binary-option-db-0002)
ok: [tyo-aws-stg-binary-option-db-0002] => (item=tyo-aws-stg-binary-option-db-0002)

TASK [common : Test SSH connectivity between nodes]
ok: [tyo-aws-stg-binary-option-db-0002] => (item=tyo-aws-stg-binary-option-db-0001)
ok: [tyo-aws-stg-binary-option-db-0001] => (item=tyo-aws-stg-binary-option-db-0002)

TASK [common : Display SSH connectivity results]
ok: [tyo-aws-stg-binary-option-db-0002] => (item=tyo-aws-stg-binary-option-db-0001) => {
    "msg": "SSH to tyo-aws-stg-binary-option-db-0001: SUCCESS"
}
ok: [tyo-aws-stg-binary-option-db-0001] => (item=tyo-aws-stg-binary-option-db-0002) => {
    "msg": "SSH to tyo-aws-stg-binary-option-db-0002: SUCCESS"
}

TASK [postgresql : Display PostgreSQL setup mode]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "=== PostgreSQL Configuration Setup ===",
        "Install PostgreSQL: True",
        "PostgreSQL Version: 17",
        "Data Directory: /dbdata/pgsql/17/data"
    ]
}
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": [
        "=== PostgreSQL Configuration Setup ===",
        "Install PostgreSQL: True",
        "PostgreSQL Version: 17",
        "Data Directory: /dbdata/pgsql/17/data"
    ]
}

TASK [postgresql : Install PGDG repo for Amazon Linux 2023 (RHEL 9 compatible)]
changed: [tyo-aws-stg-binary-option-db-0001]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [postgresql : Install PostgreSQL 17 packages (Amazon Linux 2023)]
ok: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [postgresql : Display installation result]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": "PostgreSQL 17 installation: SUCCESS"
}
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "PostgreSQL 17 installation: SUCCESS"
}

TASK [postgresql : Display PostgreSQL version]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": "Detected PostgreSQL version: postgres (PostgreSQL) 17.7"
}
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "Detected PostgreSQL version: postgres (PostgreSQL) 17.7"
}

TASK [postgresql : Initialize database with initdb]
changed: [tyo-aws-stg-binary-option-db-0001]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [postgresql : Create PostgreSQL log directory]
changed: [tyo-aws-stg-binary-option-db-0001]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [postgresql : Try to start PostgreSQL service]
changed: [tyo-aws-stg-binary-option-db-0001]
fatal: [tyo-aws-stg-binary-option-db-0002]: FAILED! => {"msg": "Unable to start service postgresql.service"}

TASK [postgresql : Start PostgreSQL using pg_ctl if systemd failed]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [postgresql : Verify PostgreSQL is accessible]
ok: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [postgresql : Display final PostgreSQL status]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": "PostgreSQL is ready and accepting connections on port 5432"
}
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "PostgreSQL is ready and accepting connections on port 5432"
}

TASK [postgresql : Display PostgreSQL connection test result]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "PostgreSQL connection test:",
        "  psycopg2 method: SUCCESS",
        "  psql command method: SUCCESS",
        "  Overall status: SUCCESS"
    ]
}
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": [
        "PostgreSQL connection test:",
        "  psycopg2 method: SUCCESS",
        "  psql command method: SUCCESS",
        "  Overall status: SUCCESS"
    ]
}

TASK [postgresql : Configure PostgreSQL for repmgr]
changed: [tyo-aws-stg-binary-option-db-0001]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [postgresql : Configure pg_hba.conf for repmgr]
changed: [tyo-aws-stg-binary-option-db-0001]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [postgresql : Create repmgr user in PostgreSQL]
changed: [tyo-aws-stg-binary-option-db-0001]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [postgresql : Create repmgr database]
changed: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [postgresql : Display repmgr verification]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "=== Repmgr User and Database Verification ===",
        [{"db_info": "Database: repmgr (Owner: repmgr)"}]
    ]
}

TASK [postgresql : Display PostgreSQL setup completion]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "=== PostgreSQL Configuration Complete ===",
        "PostgreSQL binary: /usr/bin/postgres",
        "PostgreSQL data directory: /dbdata/pgsql/17/data",
        "Configuration applied: Yes",
        "repmgr user created: Yes",
        "repmgr database created: Yes",
        "Service status: Running",
        "Ready for repmgr setup: Yes"
    ]
}

TASK [repmgr : Verify repmgr installation]
ok: [tyo-aws-stg-binary-option-db-0001]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr : Display repmgr version]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": "repmgr installed: repmgr 5.5.0"
}
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "repmgr installed: repmgr 5.5.0"
}

RUNNING HANDLER [postgresql : restart postgresql]
changed: [tyo-aws-stg-binary-option-db-0001]
changed: [tyo-aws-stg-binary-option-db-0002]

PLAY [Configure Primary Server]

TASK [Gathering Facts]
ok: [tyo-aws-stg-binary-option-db-0001]

TASK [repmgr_primary : Display PostgreSQL status]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "PostgreSQL port check: Running",
        "PostgreSQL process: Found"
    ]
}

TASK [repmgr_primary : Create repmgr extension in database]
changed: [tyo-aws-stg-binary-option-db-0001]

TASK [repmgr_primary : Display repmgr extension status]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        " extname | extversion ",
        "---------+------------",
        " repmgr  | 5.5",
        "(1 row)"
    ]
}

TASK [repmgr_primary : Create repmgr configuration file for primary]
changed: [tyo-aws-stg-binary-option-db-0001]

TASK [repmgr_primary : Register primary node with repmgr]
changed: [tyo-aws-stg-binary-option-db-0001]

TASK [repmgr_primary : Create replication slot]
changed: [tyo-aws-stg-binary-option-db-0001]

TASK [repmgr_primary : Display replication slot creation results]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "=== Replication Slot Creation ===",
        "Status: Created"
    ]
}

TASK [repmgr_primary : Display cluster status]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        " ID | Name    | Role    | Status    | Upstream | Location | Priority | Timeline | Connection string",
        "----+---------+---------+-----------+----------+----------+----------+----------+---------------------------------------------------------------",
        " 1  | primary | primary | * running |          | default  | 100      | 1        | host=10.41.241.74 user=repmgr dbname=repmgr connect_timeout=2"
    ]
}

TASK [repmgr_primary : Display final verification]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "=== Repmgr User Verification ===",
        " rolname | rolsuper | rolreplication ",
        "---------+----------+----------------",
        " repmgr  | t        | t",
        "(1 row)",
        "",
        "=== Repmgr Database Verification ===",
        " datname | owner  ",
        "---------+--------",
        " repmgr  | repmgr",
        "(1 row)",
        "",
        "=== Replication Slots ===",
        "  slot_name   | slot_type | active ",
        "--------------+-----------+--------",
        " standby_slot | physical  | f",
        "(1 row)"
    ]
}

TASK [repmgr_primary : Display primary setup completion]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "=== Primary Server Setup Complete ===",
        "PostgreSQL service running",
        "repmgr user created with SUPERUSER and REPLICATION privileges",
        "repmgr database created",
        "Primary node registered with repmgr",
        "Replication slot created for standby",
        "Ready for standby server setup"
    ]
}

TASK [Verify primary setup]
included: /tmp/postgresql-repmgr-ansible/playbooks/verify_primary.yml for tyo-aws-stg-binary-option-db-0001

TASK [Display primary verification results]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "=== Primary Server Verification ===",
        "repmgr Version: repmgr 5.5.0",
        "repmgr User: [' rolname | rolsuper | rolreplication ', '---------+----------+----------------', ' repmgr  | t        | t', '(1 row)']",
        "repmgr Database: [' datname ', '---------', ' repmgr', '(1 row)']",
        "Replication Slot: ['  slot_name   | slot_type | active ', '--------------+-----------+--------', ' standby_slot | physical  | f', '(1 row)']"
    ]
}

PLAY [Configure Standby Server]

TASK [Gathering Facts]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr_standby : Create repmgr configuration file for standby]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr_standby : Test connection to primary with exact working command]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr_standby : Display connection test results]
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": [
        "=== Primary Connection Test ===",
        "Command: PGPASSWORD=*** /usr/bin/psql -h 10.41.241.74 -U repmgr -d repmgr -c 'SELECT version();'",
        "Return code: 0",
        "Success: True",
        "Output: ['PostgreSQL 17.7 on x86_64-amazon-linux-gnu, compiled by gcc (GCC) 11.5.0 20240719 (Red Hat 11.5.0-5), 64-bit']"
    ]
}

TASK [repmgr_standby : Continue with standby setup (connection successful)]
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "Connection to primary successful - proceeding with standby setup"
}

TASK [repmgr_standby : Remove existing data directory]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr_standby : Create empty data directory with correct permissions]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr_standby : Clone standby from primary]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr_standby : Create standby.signal file]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr_standby : Display standby.signal file status]
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "Standby signal file exists: True"
}

TASK [repmgr_standby : Display updated auto configuration]
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "Updated postgresql.auto.conf: [
        \"primary_conninfo = 'host=10.41.241.74 user=repmgr application_name=standby connect_timeout=2'\",
        \"primary_slot_name = 'standby_slot'\",
        'hot_standby = on'
    ]"
}

TASK [repmgr_standby : Start PostgreSQL using pg_ctl if systemd failed]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr_standby : Wait for PostgreSQL to be ready]
ok: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr_standby : Display PostgreSQL processes]
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "PostgreSQL processes: [
        'postgres: main: startup recovering 000000010000000000000003',
        'postgres: main: walreceiver streaming 0/3000178'
    ]"
}

TASK [repmgr_standby : Show final recovery status determination]
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "Final recovery status: IN RECOVERY (STANDBY)"
}

TASK [repmgr_standby : Register standby with repmgr]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [repmgr_standby : Display cluster status]
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": [
        " ID | Name    | Role    | Status    | Upstream | Location | Priority | Timeline | Connection string",
        "----+---------+---------+-----------+----------+----------+----------+----------+----------------------------------------------------------------",
        " 1  | primary | primary | * running |          | default  | 100      | 1        | host=10.41.241.74 user=repmgr dbname=repmgr connect_timeout=2",
        " 2  | standby | standby |   running | primary  | default  | 100      | 1        | host=10.41.241.191 user=repmgr dbname=repmgr connect_timeout=2"
    ]
}

TASK [Verify standby setup]
included: /tmp/postgresql-repmgr-ansible/playbooks/verify_standby.yml for tyo-aws-stg-binary-option-db-0002

TASK [Display standby verification results]
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": [
        "=== Standby Server Verification ===",
        "Recovery Mode: [' pg_is_in_recovery ', '-------------------', ' t', '(1 row)']",
        "WAL Receiver: ['  pid   |  status   | sender_host  |  slot_name   ', '--------+-----------+--------------+--------------', ' 144394 | streaming | 10.41.241.74 | standby_slot', '(1 row)']",
        "Standby Signal: EXISTS",
        "Primary Connection: OK"
    ]
}

PLAY [Final cluster validation and optimization]

TASK [Check cluster health]
changed: [tyo-aws-stg-binary-option-db-0001]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [Display cluster health]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        " Name    | ID | 1 | 2",
        "---------+----+---+---",
        " primary | 1  | * | * ",
        " standby | 2  | * | * "
    ]
}

TASK [Display replication lag]
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "Replication lag: 2.966607 seconds"
}

TASK [Create test data on primary]
changed: [tyo-aws-stg-binary-option-db-0001]

TASK [Verify test data on standby]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [Display replication test result]
ok: [tyo-aws-stg-binary-option-db-0002] => {
    "msg": "Replication test: PASSED"
}

TASK [Clean up test data]
changed: [tyo-aws-stg-binary-option-db-0001]

TASK [Final cluster status]
changed: [tyo-aws-stg-binary-option-db-0001]
changed: [tyo-aws-stg-binary-option-db-0002]

TASK [Display final verification summary]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "=== FINAL CLUSTER VERIFICATION COMPLETE ===",
        "Cluster Status:",
        " ID | Name    | Role    | Status    | Upstream | Location | Priority | Timeline | Connection string",
        "----+---------+---------+-----------+----------+----------+----------+----------+----------------------------------------------------------------",
        " 1  | primary | primary | * running |          | default  | 100      | 1        | host=10.41.241.74 user=repmgr dbname=repmgr connect_timeout=2",
        " 2  | standby | standby |   running | primary  | default  | 100      | 1        | host=10.41.241.191 user=repmgr dbname=repmgr connect_timeout=2",
        "",
        "PostgreSQL + repmgr cluster setup completed!",
        "",
        "MANUAL FAILOVER ONLY - No automatic daemon running",
        "",
        "Next steps:",
        "1. Review failover procedures",
        "2. Test failover",
        "3. Setup monitoring",
        "4. Configure backups"
    ]
}

TASK [Display performance tuning message]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "=== Performance Tuning Applied ===",
        "Hardware-aware configuration has been applied:",
        "- Memory settings optimized for 15GB RAM",
        "- CPU settings optimized for 4 cores",
        "- Storage settings optimized for SSD",
        "- OS kernel parameters tuned for PostgreSQL"
    ]
}

TASK [Display manual failover procedures]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        "=== MANUAL FAILOVER PROCEDURES ===",
        "",
        "1. EMERGENCY FAILOVER (when primary fails):",
        "   On standby server: sudo -u postgres /usr/bin/repmgr -f /var/lib/pgsql/repmgr.conf standby promote",
        "",
        "2. PLANNED SWITCHOVER (zero downtime):",
        "   On standby server: sudo -u postgres /usr/bin/repmgr -f /var/lib/pgsql/repmgr.conf standby switchover",
        "",
        "3. CHECK CLUSTER STATUS:",
        "   sudo -u postgres /usr/bin/repmgr -f /var/lib/pgsql/repmgr.conf cluster show",
        "",
        "4. REJOIN FAILED NODE:",
        "   Stop PostgreSQL: sudo systemctl stop postgresql-17",
        "   Clone from new primary: sudo -u postgres /usr/bin/repmgr -h <new_primary_ip> -U repmgr -f /var/lib/pgsql/repmgr.conf standby clone --force",
        "   Start PostgreSQL: sudo systemctl start postgresql-17",
        "   Register: sudo -u postgres /usr/bin/repmgr -f /var/lib/pgsql/repmgr.conf standby register --force",
        "",
        "NOTE: No automatic failover daemon (repmgrd) is configured.",
        "All failover operations must be performed manually."
    ]
}

TASK [Display final cluster status]
ok: [tyo-aws-stg-binary-option-db-0001] => {
    "msg": [
        " ID | Name    | Role    | Status    | Upstream | Location | Priority | Timeline | Connection string",
        "----+---------+---------+-----------+----------+----------+----------+----------+----------------------------------------------------------------",
        " 1  | primary | primary | * running |          | default  | 100      | 1        | host=10.41.241.74 user=repmgr dbname=repmgr connect_timeout=2",
        " 2  | standby | standby |   running | primary  | default  | 100      | 1        | host=10.41.241.191 user=repmgr dbname=repmgr connect_timeout=2"
    ]
}

PLAY RECAP
tyo-aws-stg-binary-option-db-0001 : ok=135  changed=31   unreachable=0    failed=0    skipped=45   rescued=0    ignored=0
tyo-aws-stg-binary-option-db-0002 : ok=150  changed=36   unreachable=0    failed=0    skipped=47   rescued=2    ignored=0
```

### 12.4 Deployment Summary

| Server | Tasks OK | Changed | Unreachable | Failed | Skipped | Rescued |
|--------|----------|---------|-------------|--------|---------|---------|
| tyo-aws-stg-binary-option-db-0001 (Primary) | 135 | 31 | 0 | 0 | 45 | 0 |
| tyo-aws-stg-binary-option-db-0002 (Standby) | 150 | 36 | 0 | 0 | 47 | 2 |

**Notes:**
- `rescued=2` on standby is expected - systemd service fell back to pg_ctl successfully
- Both servers successfully deployed
- Replication verified working
- Cluster health check passed

---

**End of Document**
