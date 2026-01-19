# PostgreSQL HA: Self-Managed Automation vs Managed Services

## Executive Summary

This document compares **self-managed automated PostgreSQL deployment** (Infrastructure as Code) with **fully managed PostgreSQL services**. Both approaches provide automation, but differ significantly in control, cost, and operational responsibility.

---

## 1. Architecture Comparison

### 1.1 Self-Managed Automated Deployment

```
┌─────────────────────────────────────────────────────────────────────┐
│                    YOUR INFRASTRUCTURE                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐          │
│  │   PRIMARY    │    │  STANDBY 1   │    │  STANDBY 2   │          │
│  │  PostgreSQL  │───▶│  PostgreSQL  │───▶│  PostgreSQL  │          │
│  │   + repmgr   │    │   + repmgr   │    │   + repmgr   │          │
│  │ + pgBackRest │    │ + pgBackRest │    │ + pgBackRest │          │
│  └──────────────┘    └──────────────┘    └──────────────┘          │
│         │                                        │                   │
│         │            ┌──────────────┐            │                   │
│         │            │   ProxySQL   │            │                   │
│         └───────────▶│ Read/Write   │◀───────────┘                   │
│                      │   Routing    │                                │
│                      └──────────────┘                                │
│                             │                                        │
│                      ┌──────────────┐                                │
│                      │  S3 Backup   │                                │
│                      │  Repository  │                                │
│                      └──────────────┘                                │
│                                                                      │
│  Managed by: Ansible + Bash Scripts                                 │
│  Control: 100%                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 Managed Service Deployment

```
┌─────────────────────────────────────────────────────────────────────┐
│                    VENDOR INFRASTRUCTURE                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                   MANAGED PostgreSQL                         │    │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐              │    │
│  │  │ PRIMARY  │───▶│ STANDBY  │───▶│ STANDBY  │              │    │
│  │  └──────────┘    └──────────┘    └──────────┘              │    │
│  │                                                              │    │
│  │  [Automated: HA, Backups, Failover, Monitoring]             │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                             │                                        │
│                      ┌──────────────┐                                │
│                      │   Endpoint   │                                │
│                      │  (Load Bal)  │                                │
│                      └──────────────┘                                │
│                                                                      │
│  Managed by: Vendor                                                  │
│  Control: Limited to console/API parameters                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Self-Managed Automation Scripts Portfolio

Our automated deployment includes the following components:

| # | Component | Script/Document | Purpose |
|---|-----------|-----------------|---------|
| 1 | Documentation | `1_PostgreSQL_17_HA_Deployment_Runbook.md` | Deployment guide |
| 2 | PostgreSQL + repmgr | `2_generate_postgresql_17_ansible.sh` | Generates Ansible playbook |
| 3 | Backup Docs | `3_pgBackRest_Standby_Backup_Setup_Runbook.md` | Backup procedures |
| 4 | pgBackRest Setup | `4_pgbackrest_standby_backup_setup.sh` | Configures backup on PRIMARY |
| 5 | Restore Docs | `5_pgBackRest_Standby_Restore_Setup_Runbook.md` | Restore procedures |
| 6 | Standby Restore | `6_pgbackrest_standby_setup.sh` | Restores STANDBY from backup |
| 7 | S3 Guide | `7_pgBackRest_S3_Standby_Restore_Complete_Guide.md` | S3 backup/restore guide |
| 8 | ProxySQL | `8_setup_proxysql_postgresql17.sh` | Read/write query routing |

### Deployment Time

| Task | Automated Time |
|------|----------------|
| PostgreSQL 17 HA Cluster (3 nodes) | ~15-20 minutes |
| pgBackRest Configuration | ~5-10 minutes |
| Standby Restore from S3 | ~10-15 minutes |
| ProxySQL Setup | ~5 minutes |
| **Total Fresh Deployment** | **~35-50 minutes** |

---

## 3. Feature Comparison

| Feature | Self-Managed Automation | Managed Services |
|---------|------------------------|------------------|
| **Deployment** | Ansible + Bash scripts | API/Console click |
| **HA/Replication** | repmgr streaming replication | Built-in (vendor-managed) |
| **Automatic Failover** | repmgr daemon | Built-in |
| **Backup to S3** | pgBackRest (configurable) | Built-in (automatic) |
| **Point-in-Time Recovery** | pgBackRest PITR | Built-in |
| **Query Routing** | ProxySQL (customizable) | Built-in connection pooler |
| **Read/Write Splitting** | ProxySQL rules | Limited or N/A |
| **OS Access** | Full root access | None |
| **PostgreSQL Config** | 100% customizable | Limited parameters |
| **Extension Support** | Any extension | Vendor-approved only |
| **Version Control** | Any PG version | Vendor-supported versions |
| **Monitoring** | Custom (Prometheus, etc.) | Vendor dashboard |
| **Logs Access** | Full access | Limited/filtered |

---

## 4. Cost Comparison

### 4.1 Managed Service Pricing (Reference)

| Instance Type | vCPU | RAM | Storage | Monthly Cost |
|---------------|------|-----|---------|--------------|
| burstable-1 | 1 | 2GB | 16GB | $12.41 |
| burstable-2 | 2 | 4GB | 32GB | $24.81 |
| standard-2 | 2 | 8GB | 64GB | $49.00 |
| standard-4 | 4 | 16GB | 128GB | $99.00 |
| standard-8 | 8 | 32GB | 256GB | $198.00 |
| standard-16 | 16 | 64GB | 512GB | $396.00 |
| standard-30 | 30 | 120GB | 1TB | $749.00 |
| standard-60 | 60 | 240GB | 2TB | $1,498.00 |

*Note: US region pricing is ~20% higher than EU region*

### 4.2 Self-Managed on AWS (Equivalent Comparison)

| Configuration | AWS EC2 Cost | Managed Service | Savings |
|---------------|--------------|-----------------|---------|
| 2 vCPU, 8GB | ~$60-80/mo | $49-65/mo | Managed cheaper |
| 8 vCPU, 32GB | ~$150-200/mo | $198/mo | Similar |
| 16 vCPU, 64GB | ~$300-400/mo | $396/mo | Similar |

**Additional Self-Managed Costs:**
- S3 Storage: ~$0.023/GB/month
- Data Transfer: ~$0.09/GB (outbound)
- DBA Time: Variable (but you have automation)

### 4.3 3-Node HA Cluster Cost Comparison

| Setup | Self-Managed (AWS) | Managed Service |
|-------|-------------------|-----------------|
| 3x standard-4 (4 vCPU, 16GB) | ~$450-600/mo | $297/mo (single) |
| With HA (2 standbys) | Same | +$198/mo per standby |
| **Total 3-Node HA** | **~$450-600/mo** | **~$495-600/mo** |

*Note: Managed services often charge extra for HA standbys*

---

## 5. Pros and Cons

### 5.1 Self-Managed Automation

#### Pros

| Advantage | Description |
|-----------|-------------|
| **Full Control** | 100% access to OS, configs, tuning parameters |
| **Customization** | Any PostgreSQL extension, custom compilation |
| **Transparency** | Full visibility into logs, processes, issues |
| **Debugging** | Can SSH and diagnose issues (e.g., CentOS OpenSSL issue) |
| **No Vendor Lock-in** | Portable across AWS, GCP, Azure, bare metal |
| **Version Flexibility** | Run any PostgreSQL version (even beta/RC) |
| **Cost Control** | Use spot instances, reserved instances, optimize |
| **Security** | Full control over encryption, network, access |
| **Compliance** | Easier to meet specific compliance requirements |
| **Learning** | Team gains deep PostgreSQL expertise |

#### Cons

| Disadvantage | Description |
|--------------|-------------|
| **Operational Overhead** | Responsible for patching, upgrades, monitoring |
| **OS Management** | Must manage OS updates, security patches |
| **Expertise Required** | Need PostgreSQL DBA knowledge |
| **On-Call Responsibility** | Team handles incidents 24/7 |
| **Initial Setup Time** | Scripts need to be developed/maintained |
| **Scaling Complexity** | Manual intervention for scaling |

### 5.2 Managed Services

#### Pros

| Advantage | Description |
|-----------|-------------|
| **Zero OS Management** | Vendor handles OS patching |
| **Quick Setup** | Click-to-deploy, minutes to provision |
| **Built-in HA** | Automatic failover configured |
| **Automated Backups** | S3 backups without configuration |
| **Monitoring Included** | Dashboard and alerts out-of-box |
| **Support Included** | Vendor support for issues |
| **Reduced On-Call** | Vendor handles infrastructure issues |

#### Cons

| Disadvantage | Description |
|--------------|-------------|
| **Limited Control** | Cannot access OS or tune deeply |
| **Vendor Lock-in** | Migration requires planning |
| **Extension Limits** | Only vendor-approved extensions |
| **Version Lag** | New PG versions available later |
| **Black Box** | Limited visibility into issues |
| **Cost Premium** | Management fee included in price |
| **Compliance Challenges** | May not meet specific requirements |
| **Network Constraints** | Limited network customization |

---

## 6. Decision Matrix

### When to Choose Self-Managed Automation

| Scenario | Recommendation |
|----------|----------------|
| Need specific PostgreSQL extensions | Self-Managed |
| Strict compliance requirements (PCI, HIPAA) | Self-Managed |
| Cost optimization is critical | Self-Managed |
| Team has PostgreSQL expertise | Self-Managed |
| Need deep performance tuning | Self-Managed |
| Multi-cloud or hybrid deployment | Self-Managed |
| Custom monitoring/alerting required | Self-Managed |
| Running PostgreSQL beta/new versions | Self-Managed |

### When to Choose Managed Services

| Scenario | Recommendation |
|----------|----------------|
| Small team, no DBA | Managed Service |
| Rapid prototyping needed | Managed Service |
| Minimal PostgreSQL customization | Managed Service |
| Don't want on-call responsibility | Managed Service |
| Standard workloads, standard configs | Managed Service |
| Budget includes management premium | Managed Service |

---

## 7. Hybrid Approach

Consider a hybrid strategy:

```
┌─────────────────────────────────────────────────────────────────┐
│                     HYBRID ARCHITECTURE                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   PRODUCTION (Critical)          DEV/STAGING (Non-Critical)     │
│   ┌─────────────────┐            ┌─────────────────┐            │
│   │  Self-Managed   │            │ Managed Service │            │
│   │  PostgreSQL HA  │            │   PostgreSQL    │            │
│   │  (Full Control) │            │  (Quick Setup)  │            │
│   └─────────────────┘            └─────────────────┘            │
│                                                                  │
│   Benefits:                                                      │
│   - Production: Full control, optimization, compliance          │
│   - Dev/Staging: Quick provisioning, low maintenance            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 8. Real-World Example: CentOS 7 OpenSSL Issue

### Issue Encountered
Production PRIMARY server running CentOS 7 with OpenSSL 1.0.x caused **segmentation fault** when connecting to S3 for pgBackRest backups.

### Self-Managed Response
1. SSH to server and debug
2. Identify root cause (OpenSSL incompatibility)
3. Implement workaround (WAL sync from STANDBY)
4. Document for future reference

### Managed Service Response
- Would see: "Backup failed"
- Limited visibility into root cause
- Dependent on vendor support ticket
- No ability to implement custom workaround

**This example demonstrates the value of self-managed approach for troubleshooting and custom solutions.**

---

## 9. Conclusion

| Criteria | Winner |
|----------|--------|
| **Control & Flexibility** | Self-Managed |
| **Ease of Setup** | Managed Service |
| **Cost (at scale)** | Self-Managed |
| **Operational Overhead** | Managed Service |
| **Troubleshooting Ability** | Self-Managed |
| **Time to Market** | Managed Service |
| **Long-term Ownership** | Self-Managed |

### Recommendation

For organizations with:
- **PostgreSQL expertise** → Self-Managed Automation
- **Critical production workloads** → Self-Managed Automation
- **Compliance requirements** → Self-Managed Automation
- **Limited DBA resources** → Managed Service
- **Non-critical workloads** → Managed Service

Our self-managed automation scripts provide the **best of both worlds**: automated deployment speed with full operational control.

---

## 10. References

- PostgreSQL 17 Documentation: https://www.postgresql.org/docs/17/
- pgBackRest Documentation: https://pgbackrest.org/
- repmgr Documentation: https://www.repmgr.org/
- ProxySQL Documentation: https://proxysql.com/documentation/

---

*Document Version: 1.0*
*Created: January 2026*
*Author: DBA Automation Team*
