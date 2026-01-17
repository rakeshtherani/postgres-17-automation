#!/bin/bash

# ProxySQL Setup Script for PostgreSQL 17 with Streaming Replication
# Designed for Amazon Linux 2023 / RHEL / CentOS with PostgreSQL 17
# Version: 3.0
# Date: 2026-01-17

set -e

#===============================================================================
# Configuration Variables - UPDATE THESE FOR YOUR ENVIRONMENT
#===============================================================================

# PostgreSQL Servers
PRIMARY_HOST="${PRIMARY_HOST:-10.41.241.74}"
STANDBY1_HOST="${STANDBY1_HOST:-10.41.241.191}"
STANDBY2_HOST="${STANDBY2_HOST:-10.41.241.171}"
PROXYSQL_HOST="${PROXYSQL_HOST:-$(hostname -I | awk '{print $1}')}"

# PostgreSQL Version
PG_VERSION="${PG_VERSION:-17}"

# ProxySQL Configuration
PROXYSQL_VERSION="3.0.2"
PROXYSQL_ADMIN_PORT="6132"
PROXYSQL_PGSQL_PORT="6133"
PROXYSQL_ADMIN_USER="admin"
PROXYSQL_ADMIN_PASS="${PROXYSQL_ADMIN_PASS:-admin}"

# Database Users
MONITOR_USER="proxysql_monitor"
MONITOR_PASS="${MONITOR_PASS:-ProxySQL_Monitor_2026!}"
APP_USER="${APP_USER:-app_user}"
APP_PASS="${APP_PASS:-App_Password_2026!}"

# Database Configuration
DB_NAME="${DB_NAME:-postgres}"
REPMGR_DB="repmgr"

#===============================================================================
# Color and Logging Functions
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1"
}

#===============================================================================
# Pre-flight Checks
#===============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

show_config() {
    echo ""
    echo "==============================================================================="
    echo "  ProxySQL Setup for PostgreSQL ${PG_VERSION}"
    echo "==============================================================================="
    echo ""
    info "Configuration:"
    echo "  Primary Host:      ${PRIMARY_HOST}"
    echo "  Standby 1 Host:    ${STANDBY1_HOST}"
    echo "  Standby 2 Host:    ${STANDBY2_HOST}"
    echo "  ProxySQL Host:     ${PROXYSQL_HOST}"
    echo "  Admin Port:        ${PROXYSQL_ADMIN_PORT}"
    echo "  PostgreSQL Port:   ${PROXYSQL_PGSQL_PORT}"
    echo "  App User:          ${APP_USER}"
    echo "  Monitor User:      ${MONITOR_USER}"
    echo ""
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check connectivity to PostgreSQL servers
    for host in "$PRIMARY_HOST" "$STANDBY1_HOST" "$STANDBY2_HOST"; do
        if [[ -n "$host" ]]; then
            if ping -c 1 -W 2 "$host" &>/dev/null; then
                info "Connectivity to $host: OK"
            else
                warning "Cannot reach $host - will skip this server"
            fi
        fi
    done

    # Check if psql is available
    if ! command -v psql &>/dev/null; then
        warning "psql not found, installing PostgreSQL client..."
        dnf install -y postgresql${PG_VERSION} 2>/dev/null || \
        yum install -y postgresql${PG_VERSION} 2>/dev/null || \
        dnf install -y postgresql 2>/dev/null || true
    fi

    log "Prerequisites check completed"
}

#===============================================================================
# ProxySQL Installation
#===============================================================================

install_proxysql() {
    log "Installing ProxySQL ${PROXYSQL_VERSION}..."

    if command -v proxysql &>/dev/null; then
        warning "ProxySQL is already installed"
        proxysql --version
        systemctl stop proxysql 2>/dev/null || true
    else
        cd /tmp

        # Download ProxySQL 3.0.2 for AlmaLinux 9 (compatible with Amazon Linux 2023)
        log "Downloading ProxySQL ${PROXYSQL_VERSION}..."
        curl -LO "https://github.com/sysown/proxysql/releases/download/v${PROXYSQL_VERSION}/proxysql-${PROXYSQL_VERSION}-1-almalinux9.x86_64.rpm" || \
        error "Failed to download ProxySQL"

        # Install dependencies
        log "Installing dependencies..."
        dnf install -y gnutls perl-DBI 2>/dev/null || \
        yum install -y gnutls perl-DBI 2>/dev/null || true

        # Install ProxySQL
        log "Installing ProxySQL package..."
        rpm -ivh --nodeps "proxysql-${PROXYSQL_VERSION}-1-almalinux9.x86_64.rpm" || \
        error "Failed to install ProxySQL"

        # Cleanup
        rm -f "/tmp/proxysql-${PROXYSQL_VERSION}-1-almalinux9.x86_64.rpm"
    fi

    # Verify installation
    if proxysql --version &>/dev/null; then
        success "ProxySQL installed successfully"
        proxysql --version
    else
        error "ProxySQL installation verification failed"
    fi
}

#===============================================================================
# ProxySQL Configuration
#===============================================================================

configure_proxysql() {
    log "Configuring ProxySQL..."

    # Backup original configuration
    if [[ -f /etc/proxysql.cnf ]]; then
        cp /etc/proxysql.cnf "/etc/proxysql.cnf.bak.$(date +%Y%m%d_%H%M%S)"
    fi

    # Create ProxySQL configuration for PostgreSQL
    cat > /etc/proxysql.cnf << EOF
datadir="/var/lib/proxysql"
errorlog="/var/log/proxysql/proxysql.log"

admin_variables=
{
    admin_credentials="${PROXYSQL_ADMIN_USER}:${PROXYSQL_ADMIN_PASS}"
    pgsql_ifaces="0.0.0.0:${PROXYSQL_ADMIN_PORT}"
}

pgsql_variables=
{
    threads=4
    max_connections=2048
    default_query_delay=0
    default_query_timeout=36000000
    have_compress=true
    poll_timeout=2000
    interfaces="0.0.0.0:${PROXYSQL_PGSQL_PORT}"
    default_schema="public"
    stacksize=1048576
    server_version="${PG_VERSION}.0"
    connect_timeout_server=3000
    monitor_username="${MONITOR_USER}"
    monitor_password="${MONITOR_PASS}"
    monitor_history=600000
    monitor_connect_interval=60000
    monitor_ping_interval=10000
    ping_interval_server_msec=120000
    ping_timeout_server=500
    commands_stats=true
    sessions_sort=true
    monitor_enabled=true
}
EOF

    success "ProxySQL configuration created"
}

#===============================================================================
# Start ProxySQL Service
#===============================================================================

start_proxysql() {
    log "Starting ProxySQL service..."

    # Create required directories
    mkdir -p /var/log/proxysql /var/lib/proxysql
    chown -R proxysql:proxysql /var/log/proxysql /var/lib/proxysql 2>/dev/null || true

    # Remove old SQLite database to ensure clean start
    rm -f /var/lib/proxysql/proxysql.db 2>/dev/null || true

    # Start ProxySQL
    systemctl start proxysql
    systemctl enable proxysql

    # Wait for startup
    sleep 5

    # Verify service is running
    if systemctl is-active proxysql &>/dev/null; then
        success "ProxySQL service started"
    else
        error "Failed to start ProxySQL service"
    fi

    # Verify ports
    if ss -tlnp | grep -q ":${PROXYSQL_ADMIN_PORT}"; then
        info "Admin port ${PROXYSQL_ADMIN_PORT} is listening"
    else
        error "Admin port ${PROXYSQL_ADMIN_PORT} is not listening"
    fi

    if ss -tlnp | grep -q ":${PROXYSQL_PGSQL_PORT}"; then
        info "PostgreSQL port ${PROXYSQL_PGSQL_PORT} is listening"
    else
        error "PostgreSQL port ${PROXYSQL_PGSQL_PORT} is not listening"
    fi
}

#===============================================================================
# Create PostgreSQL Users
#===============================================================================

create_postgresql_users() {
    log "Creating PostgreSQL users on primary server..."

    # Create users via SSH to primary
    ssh -o StrictHostKeyChecking=no "root@${PRIMARY_HOST}" << EOSSH
    sudo -u postgres psql << 'EOSQL'

    -- Create monitoring user
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${MONITOR_USER}') THEN
            CREATE USER ${MONITOR_USER} WITH PASSWORD '${MONITOR_PASS}';
            RAISE NOTICE 'User ${MONITOR_USER} created';
        ELSE
            ALTER USER ${MONITOR_USER} WITH PASSWORD '${MONITOR_PASS}';
            RAISE NOTICE 'User ${MONITOR_USER} password updated';
        END IF;
    END
    \$\$;

    -- Grant monitor permissions
    GRANT CONNECT ON DATABASE postgres TO ${MONITOR_USER};
    GRANT pg_monitor TO ${MONITOR_USER};

    -- Create application user
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_USER}') THEN
            CREATE USER ${APP_USER} WITH PASSWORD '${APP_PASS}';
            RAISE NOTICE 'User ${APP_USER} created';
        ELSE
            ALTER USER ${APP_USER} WITH PASSWORD '${APP_PASS}';
            RAISE NOTICE 'User ${APP_USER} password updated';
        END IF;
    END
    \$\$;

    -- Grant application user permissions
    GRANT CONNECT ON DATABASE postgres TO ${APP_USER};
    GRANT ALL PRIVILEGES ON DATABASE postgres TO ${APP_USER};

    -- Show created users
    SELECT usename, usesuper, usecreatedb FROM pg_user
    WHERE usename IN ('${MONITOR_USER}', '${APP_USER}');

EOSQL
EOSSH

    success "PostgreSQL users created/updated"
}

#===============================================================================
# Update pg_hba.conf on All Servers
#===============================================================================

update_pg_hba() {
    log "Updating pg_hba.conf on PostgreSQL servers..."

    local PG_HBA_ENTRY="
# ProxySQL connections
host    all             ${MONITOR_USER}    ${PROXYSQL_HOST}/32       scram-sha-256
host    all             ${APP_USER}        ${PROXYSQL_HOST}/32       scram-sha-256
host    all             ${MONITOR_USER}    10.0.0.0/8                scram-sha-256
host    all             ${APP_USER}        10.0.0.0/8                scram-sha-256
"

    for host in "$PRIMARY_HOST" "$STANDBY1_HOST" "$STANDBY2_HOST"; do
        if [[ -n "$host" ]]; then
            log "Updating pg_hba.conf on ${host}..."
            ssh -o StrictHostKeyChecking=no "root@${host}" << EOSSH || warning "Failed to update ${host}"

            PG_HBA="\$(sudo -u postgres psql -t -c "SHOW hba_file;" | xargs)"

            if [[ -z "\$PG_HBA" ]]; then
                PG_HBA="/dbdata/pgsql/${PG_VERSION}/data/pg_hba.conf"
            fi

            # Backup
            cp "\$PG_HBA" "\${PG_HBA}.bak.\$(date +%Y%m%d_%H%M%S)"

            # Add ProxySQL entries if not exists
            if ! grep -q "ProxySQL connections" "\$PG_HBA"; then
                echo '${PG_HBA_ENTRY}' >> "\$PG_HBA"
                echo "Added ProxySQL entries to \$PG_HBA"
            else
                echo "ProxySQL entries already exist in \$PG_HBA"
            fi

            # Reload PostgreSQL
            sudo -u postgres psql -c "SELECT pg_reload_conf();"
EOSSH
        fi
    done

    success "pg_hba.conf updated on all servers"
}

#===============================================================================
# Configure ProxySQL Runtime
#===============================================================================

configure_proxysql_runtime() {
    log "Configuring ProxySQL runtime settings..."

    sleep 3

    # Connect to ProxySQL admin and configure
    PGPASSWORD="${PROXYSQL_ADMIN_PASS}" psql -h 127.0.0.1 -p "${PROXYSQL_ADMIN_PORT}" -U "${PROXYSQL_ADMIN_USER}" -d main << EOF

    -- Clear existing configuration
    DELETE FROM pgsql_servers;
    DELETE FROM pgsql_users;
    DELETE FROM pgsql_query_rules;
    DELETE FROM pgsql_replication_hostgroups;

    -- Add PostgreSQL servers
    -- Hostgroup 1: Primary (writes)
    INSERT INTO pgsql_servers (hostgroup_id, hostname, port, weight, max_connections, comment)
    VALUES (1, '${PRIMARY_HOST}', 5432, 1000, 500, 'Primary PostgreSQL - Writes');

    -- Hostgroup 2: Standbys (reads)
    INSERT INTO pgsql_servers (hostgroup_id, hostname, port, weight, max_connections, comment)
    VALUES (2, '${STANDBY1_HOST}', 5432, 1000, 300, 'Standby 1 PostgreSQL - Reads');

    INSERT INTO pgsql_servers (hostgroup_id, hostname, port, weight, max_connections, comment)
    VALUES (2, '${STANDBY2_HOST}', 5432, 1000, 300, 'Standby 2 PostgreSQL - Reads');

    -- Also add primary to read hostgroup with lower weight (fallback)
    INSERT INTO pgsql_servers (hostgroup_id, hostname, port, weight, max_connections, comment)
    VALUES (2, '${PRIMARY_HOST}', 5432, 100, 100, 'Primary PostgreSQL - Read Fallback');

    -- Add application user
    INSERT INTO pgsql_users (username, password, active, default_hostgroup, max_connections, comment)
    VALUES ('${APP_USER}', '${APP_PASS}', 1, 2, 1000, 'Application User');

    -- Query routing rules
    -- Rule 1: Route writes to primary (hostgroup 1)
    INSERT INTO pgsql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
    VALUES (1, 1, '^(INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TRUNCATE|GRANT|REVOKE).*', 1, 1, 'Route writes to primary');

    -- Rule 2: Route transactions to primary
    INSERT INTO pgsql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
    VALUES (2, 1, '^(BEGIN|START|COMMIT|ROLLBACK|SAVEPOINT|RELEASE).*', 1, 1, 'Route transactions to primary');

    -- Rule 3: Route SELECTs to standbys (hostgroup 2)
    INSERT INTO pgsql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
    VALUES (3, 1, '^SELECT.*', 2, 1, 'Route reads to standbys');

    -- Rule 4: Route SET commands to primary
    INSERT INTO pgsql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
    VALUES (4, 1, '^SET.*', 1, 1, 'Route SET to primary');

    -- Configure replication hostgroups
    INSERT INTO pgsql_replication_hostgroups (writer_hostgroup, reader_hostgroup, comment)
    VALUES (1, 2, 'Primary-Standby replication setup');

    -- Update monitoring settings
    UPDATE global_variables SET variable_value = '${MONITOR_USER}'
    WHERE variable_name = 'pgsql-monitor_username';

    UPDATE global_variables SET variable_value = '${MONITOR_PASS}'
    WHERE variable_name = 'pgsql-monitor_password';

    UPDATE global_variables SET variable_value = 'true'
    WHERE variable_name = 'pgsql-monitor_enabled';

    -- Load configuration to runtime
    LOAD PGSQL SERVERS TO RUNTIME;
    LOAD PGSQL USERS TO RUNTIME;
    LOAD PGSQL QUERY RULES TO RUNTIME;
    LOAD PGSQL VARIABLES TO RUNTIME;

    -- Save configuration to disk
    SAVE PGSQL SERVERS TO DISK;
    SAVE PGSQL USERS TO DISK;
    SAVE PGSQL QUERY RULES TO DISK;
    SAVE PGSQL VARIABLES TO DISK;

    -- Verify configuration
    \echo '=== Configured Servers ==='
    SELECT hostgroup_id, hostname, port, weight, status, comment FROM runtime_pgsql_servers ORDER BY hostgroup_id;

    \echo '=== Configured Users ==='
    SELECT username, default_hostgroup, max_connections FROM runtime_pgsql_users;

    \echo '=== Query Rules ==='
    SELECT rule_id, match_pattern, destination_hostgroup, comment FROM runtime_pgsql_query_rules ORDER BY rule_id;

EOF

    success "ProxySQL runtime configuration completed"
}

#===============================================================================
# Test ProxySQL
#===============================================================================

test_proxysql() {
    log "Testing ProxySQL connectivity..."

    echo ""
    info "Testing admin interface..."
    if PGPASSWORD="${PROXYSQL_ADMIN_PASS}" psql -h 127.0.0.1 -p "${PROXYSQL_ADMIN_PORT}" -U "${PROXYSQL_ADMIN_USER}" -d main -c "SELECT 'Admin connection OK' as status;" 2>/dev/null; then
        success "Admin interface: OK"
    else
        warning "Admin interface test failed"
    fi

    echo ""
    info "Testing application connection..."
    if PGPASSWORD="${APP_PASS}" psql -h 127.0.0.1 -p "${PROXYSQL_PGSQL_PORT}" -U "${APP_USER}" -d "${DB_NAME}" -c "SELECT 'App connection OK' as status;" 2>/dev/null; then
        success "Application connection: OK"
    else
        warning "Application connection test failed (this is expected if DB doesn't exist yet)"
    fi

    echo ""
    info "Testing read query routing..."
    for i in 1 2 3; do
        echo -n "  Read test $i - Server: "
        PGPASSWORD="${APP_PASS}" psql -h 127.0.0.1 -p "${PROXYSQL_PGSQL_PORT}" -U "${APP_USER}" -d "${DB_NAME}" -t -c "SELECT inet_server_addr();" 2>/dev/null | tr -d ' ' || echo "N/A"
    done

    success "ProxySQL tests completed"
}

#===============================================================================
# Show Status
#===============================================================================

show_status() {
    log "ProxySQL Status Summary"
    echo ""
    echo "==============================================================================="

    PGPASSWORD="${PROXYSQL_ADMIN_PASS}" psql -h 127.0.0.1 -p "${PROXYSQL_ADMIN_PORT}" -U "${PROXYSQL_ADMIN_USER}" -d main << EOF

    \echo 'PostgreSQL Servers:'
    SELECT hostgroup_id as hg, hostname, port, status, weight, max_connections as max_conn
    FROM runtime_pgsql_servers
    ORDER BY hostgroup_id, hostname;

    \echo ''
    \echo 'Connection Pool Status:'
    SELECT hostgroup as hg, srv_host, srv_port, status, ConnUsed, ConnFree, ConnOK, ConnERR
    FROM stats_pgsql_connection_pool
    ORDER BY hostgroup, srv_host;

    \echo ''
    \echo 'Replication Hostgroups:'
    SELECT * FROM pgsql_replication_hostgroups;

EOF

    echo "==============================================================================="
    echo ""
    success "Configuration Summary:"
    echo "  Primary Server:     ${PRIMARY_HOST}:5432 (Hostgroup 1 - Writes)"
    echo "  Standby 1:          ${STANDBY1_HOST}:5432 (Hostgroup 2 - Reads)"
    echo "  Standby 2:          ${STANDBY2_HOST}:5432 (Hostgroup 2 - Reads)"
    echo ""
    echo "  ProxySQL Admin:     ${PROXYSQL_HOST}:${PROXYSQL_ADMIN_PORT}"
    echo "  ProxySQL App Port:  ${PROXYSQL_HOST}:${PROXYSQL_PGSQL_PORT}"
    echo ""
    echo "  Application User:   ${APP_USER}"
    echo "  Monitor User:       ${MONITOR_USER}"
    echo "==============================================================================="
}

#===============================================================================
# Print Usage
#===============================================================================

print_usage() {
    echo ""
    echo "==============================================================================="
    echo "  ProxySQL Setup Complete!"
    echo "==============================================================================="
    echo ""
    echo "Connect to ProxySQL Admin:"
    echo "  PGPASSWORD=${PROXYSQL_ADMIN_PASS} psql -h 127.0.0.1 -p ${PROXYSQL_ADMIN_PORT} -U admin -d main"
    echo ""
    echo "Connect Application:"
    echo "  PGPASSWORD=${APP_PASS} psql -h ${PROXYSQL_HOST} -p ${PROXYSQL_PGSQL_PORT} -U ${APP_USER} -d ${DB_NAME}"
    echo ""
    echo "Monitor ProxySQL:"
    echo "  tail -f /var/log/proxysql/proxysql.log"
    echo ""
    echo "Check Server Status:"
    echo "  ./verify_proxysql.sh"
    echo ""
    echo "==============================================================================="
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
    show_config

    read -p "Do you want to proceed with ProxySQL setup? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        info "Setup cancelled by user"
        exit 0
    fi

    check_root
    check_prerequisites
    install_proxysql
    configure_proxysql
    start_proxysql
    create_postgresql_users
    update_pg_hba
    configure_proxysql_runtime
    test_proxysql
    show_status
    print_usage

    success "ProxySQL setup completed successfully!"
}

# Run main function
main "$@"
