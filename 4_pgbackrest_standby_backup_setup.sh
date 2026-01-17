#!/bin/bash
#===============================================================================
# pgBackRest Standby Backup Setup Script (Unified)
#
# This script handles:
# 1. Setting up pgBackRest on a STANDBY server for taking backups
# 2. Taking backups from standby (reduces primary load)
# 3. Creating EBS snapshots for quick standby creation (EBS mode)
# 4. Backing up to S3 bucket (S3 mode)
# 5. Works with existing repmgr cluster setup
# 6. Can be used for both initial setup and scheduled backups
#
# Usage:
#   Initial setup: ./pgbackrest_standby_backup_setup.sh
#   Scheduled run: ./pgbackrest_standby_backup_setup.sh --scheduled
#
# Storage Options:
#   - EBS: Local EBS volume with snapshots (default)
#   - S3:  AWS S3 bucket for backups
#
# The snapshots/backups created can be used with pgbackrest_standby_setup.sh
# to create new standby servers
#
# Author: Unified Standby Backup Script
# Version: 3.0 - PostgreSQL 17 with S3/EBS support
#===============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Default configuration - MODIFY THESE VALUES FOR YOUR ENVIRONMENT
readonly DEFAULT_PRIMARY_IP="10.41.241.74"
readonly DEFAULT_STANDBY_IP="10.41.241.191"  # The standby where backups will run
readonly DEFAULT_PG_VERSION="17"
readonly DEFAULT_STANZA_NAME="pg17_cluster"
readonly DEFAULT_BACKUP_VOLUME_SIZE="200"
readonly DEFAULT_AWS_REGION="ap-northeast-1"
readonly DEFAULT_AVAILABILITY_ZONE="ap-northeast-1a"

# Storage type configuration - "ebs" or "s3"
readonly DEFAULT_STORAGE_TYPE="ebs"

# S3 configuration (used when STORAGE_TYPE=s3)
readonly DEFAULT_S3_BUCKET=""  # e.g., "my-pgbackrest-bucket"
readonly DEFAULT_S3_REGION="ap-northeast-1"
readonly DEFAULT_S3_ENDPOINT="s3.ap-northeast-1.amazonaws.com"

# Custom data directory (for non-standard installations)
readonly DEFAULT_CUSTOM_DATA_DIR="/dbdata/pgsql/17/data"

# Configuration variables
PRIMARY_IP="${PRIMARY_IP:-$DEFAULT_PRIMARY_IP}"
STANDBY_IP="${STANDBY_IP:-$DEFAULT_STANDBY_IP}"
PG_VERSION="${PG_VERSION:-$DEFAULT_PG_VERSION}"
STANZA_NAME="${STANZA_NAME:-$DEFAULT_STANZA_NAME}"
BACKUP_VOLUME_SIZE="${BACKUP_VOLUME_SIZE:-$DEFAULT_BACKUP_VOLUME_SIZE}"
AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
AVAILABILITY_ZONE="${AVAILABILITY_ZONE:-$DEFAULT_AVAILABILITY_ZONE}"
SETUP_PERIODIC_SNAPSHOTS="${SETUP_PERIODIC_SNAPSHOTS:-true}"

# Storage type and S3 configuration
STORAGE_TYPE="${STORAGE_TYPE:-$DEFAULT_STORAGE_TYPE}"
S3_BUCKET="${S3_BUCKET:-$DEFAULT_S3_BUCKET}"
S3_REGION="${S3_REGION:-$DEFAULT_S3_REGION}"
S3_ENDPOINT="${S3_ENDPOINT:-$DEFAULT_S3_ENDPOINT}"

# Custom data directory
CUSTOM_DATA_DIR="${CUSTOM_DATA_DIR:-$DEFAULT_CUSTOM_DATA_DIR}"

# Backup scheduling configuration
BACKUP_MODE="${BACKUP_MODE:-auto}"  # auto, setup, full, incr, skip
FORCE_FULL_BACKUP="${FORCE_FULL_BACKUP:-false}"
SKIP_SNAPSHOT="${SKIP_SNAPSHOT:-false}"
SKIP_BACKUP="${SKIP_BACKUP:-false}"
CLEANUP_OLD_SNAPSHOTS="${CLEANUP_OLD_SNAPSHOTS:-true}"

# Derived configuration
# Use custom data directory if specified, otherwise use standard path
if [[ -n "$CUSTOM_DATA_DIR" ]] && [[ "$CUSTOM_DATA_DIR" != "/var/lib/pgsql/${PG_VERSION}/data" ]]; then
    PG_DATA_DIR="$CUSTOM_DATA_DIR"
else
    PG_DATA_DIR="/var/lib/pgsql/${PG_VERSION}/data"
fi

# PostgreSQL binary directory - check multiple locations
if [ -d "/usr/pgsql-${PG_VERSION}/bin" ]; then
    PG_BIN_DIR="/usr/pgsql-${PG_VERSION}/bin"
elif [ -d "/usr/local/pgsql/bin" ]; then
    PG_BIN_DIR="/usr/local/pgsql/bin"
else
    PG_BIN_DIR="/usr/bin"
fi

readonly BACKUP_MOUNT_POINT="/backup/pgbackrest"
readonly BACKUP_DEVICE="/dev/xvdb"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/pgbackrest_standby_backup_$(date +%Y%m%d_%H%M%S).log"
readonly STATE_FILE="${SCRIPT_DIR}/pgbackrest_standby_backup_state.env"

# Check if we have local repmgr binary path
REPMGR_BIN="/usr/local/pgsql/bin/repmgr"
if [ ! -f "$REPMGR_BIN" ]; then
    REPMGR_BIN="/usr/pgsql-${PG_VERSION}/bin/repmgr"
fi
if [ ! -f "$REPMGR_BIN" ]; then
    REPMGR_BIN=$(which repmgr 2>/dev/null || echo "/usr/bin/repmgr")
fi

# Global variables
BACKUP_VOLUME_ID=""
SNAPSHOT_ID=""
SCHEDULED_MODE=false

#===============================================================================
# Utility Functions
#===============================================================================

get_current_server_ip() {
    # Get the IP address of the current server
    # Try multiple methods to ensure we get the correct IP

    # Method 1: Get IP from hostname -I (most reliable for internal IPs)
    local ip_list=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^10\.|^172\.|^192\.168\.' | head -1)

    if [[ -n "$ip_list" ]]; then
        echo "$ip_list"
        return
    fi

    # Method 2: Get IP from ip command
    local ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -E '^10\.|^172\.|^192\.168\.' | head -1)

    if [[ -n "$ip_addr" ]]; then
        echo "$ip_addr"
        return
    fi

    # Method 3: Get IP that can reach the primary
    local primary_ip="${PRIMARY_IP:-$DEFAULT_PRIMARY_IP}"
    local route_ip=$(ip route get "$primary_ip" 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}' | head -1)

    if [[ -n "$route_ip" ]]; then
        echo "$route_ip"
        return
    fi

    # If all methods fail, return empty
    echo ""
}

log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${CYAN}[${timestamp}]${NC} ${message}" | tee -a "$LOG_FILE"
}

log_success() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[${timestamp}] ✅ ${message}${NC}" | tee -a "$LOG_FILE"
}

log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[${timestamp}] ❌ ERROR: ${message}${NC}" | tee -a "$LOG_FILE"
}

log_warning() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[${timestamp}] ⚠️  WARNING: ${message}${NC}" | tee -a "$LOG_FILE"
}

log_info() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}[${timestamp}] ℹ️  INFO: ${message}${NC}" | tee -a "$LOG_FILE"
}

check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command '$cmd' not found"
        exit 1
    fi
}

save_state() {
    local key="$1"
    local value="$2"

    # Create or update state file
    if [ -f "$STATE_FILE" ]; then
        # Remove existing key if present
        grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || touch "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi

    # Add new key-value pair
    echo "${key}=${value}" >> "$STATE_FILE"
    log_info "State saved: ${key}=${value}"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        log_info "State loaded from: $STATE_FILE"
    else
        log_info "No existing state file found"
    fi
}

#===============================================================================
# Storage Type Selection
#===============================================================================

prompt_storage_type() {
    # Skip prompt in scheduled mode or if already configured
    if [[ "$SCHEDULED_MODE" == "true" ]]; then
        return 0
    fi

    # Check if storage type is already set via environment variable
    if [[ -n "${STORAGE_TYPE_SET:-}" ]]; then
        return 0
    fi

    echo
    log_info "=== BACKUP STORAGE TYPE SELECTION ==="
    echo
    echo -e "${CYAN}Choose where to store your backups:${NC}"
    echo
    echo "  1) EBS (Local EBS Volume)"
    echo "     - Fast local backups with EBS snapshots"
    echo "     - Good for quick standby provisioning"
    echo "     - Requires additional EBS volume"
    echo
    echo "  2) S3 (AWS S3 Bucket)"
    echo "     - Durable, unlimited storage"
    echo "     - Lower cost for long-term retention"
    echo "     - Requires S3 bucket and IAM permissions"
    echo
    echo "  3) Both (EBS + S3)"
    echo "     - Local EBS for fast recovery"
    echo "     - S3 for disaster recovery"
    echo "     - Best protection, higher cost"
    echo

    while true; do
        read -p "Select storage type [1/2/3] (default: 1): " storage_choice
        storage_choice="${storage_choice:-1}"

        case $storage_choice in
            1)
                STORAGE_TYPE="ebs"
                log_info "Selected: EBS storage"
                break
                ;;
            2)
                STORAGE_TYPE="s3"
                log_info "Selected: S3 storage"

                # Prompt for S3 bucket if not set
                if [[ -z "$S3_BUCKET" ]]; then
                    read -p "Enter S3 bucket name: " S3_BUCKET
                    if [[ -z "$S3_BUCKET" ]]; then
                        log_error "S3 bucket name is required for S3 storage"
                        continue
                    fi
                fi

                # Prompt for S3 region
                read -p "Enter S3 region (default: $S3_REGION): " input_region
                S3_REGION="${input_region:-$S3_REGION}"

                log_info "S3 Bucket: $S3_BUCKET"
                log_info "S3 Region: $S3_REGION"
                break
                ;;
            3)
                STORAGE_TYPE="both"
                log_info "Selected: EBS + S3 storage"

                # Prompt for S3 bucket if not set
                if [[ -z "$S3_BUCKET" ]]; then
                    read -p "Enter S3 bucket name: " S3_BUCKET
                    if [[ -z "$S3_BUCKET" ]]; then
                        log_error "S3 bucket name is required"
                        continue
                    fi
                fi

                # Prompt for S3 region
                read -p "Enter S3 region (default: $S3_REGION): " input_region
                S3_REGION="${input_region:-$S3_REGION}"

                log_info "S3 Bucket: $S3_BUCKET"
                log_info "S3 Region: $S3_REGION"
                break
                ;;
            *)
                log_warning "Invalid choice. Please enter 1, 2, or 3."
                ;;
        esac
    done

    # Mark storage type as set
    STORAGE_TYPE_SET="true"
    save_state "STORAGE_TYPE" "$STORAGE_TYPE"

    if [[ "$STORAGE_TYPE" == "s3" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
        save_state "S3_BUCKET" "$S3_BUCKET"
        save_state "S3_REGION" "$S3_REGION"
    fi
}

validate_s3_access() {
    if [[ "$STORAGE_TYPE" != "s3" ]] && [[ "$STORAGE_TYPE" != "both" ]]; then
        return 0
    fi

    log_info "Validating S3 access..."

    # Check if bucket exists and is accessible
    if ! aws s3 ls "s3://${S3_BUCKET}" --region "$S3_REGION" &>/dev/null; then
        log_error "Cannot access S3 bucket: $S3_BUCKET"
        log_error "Please ensure:"
        log_error "  1. The bucket exists"
        log_error "  2. AWS credentials have s3:ListBucket, s3:GetObject, s3:PutObject permissions"
        log_error "  3. The bucket region is correct: $S3_REGION"
        return 1
    fi

    log_success "S3 bucket access validated: $S3_BUCKET"
    return 0
}

#===============================================================================
# Smart Backup Type Detection
#===============================================================================

determine_backup_type() {
    # If backup is explicitly skipped
    if [[ "$SKIP_BACKUP" == "true" ]] || [[ "$BACKUP_MODE" == "skip" ]]; then
        echo "skip"
        return
    fi

    # If explicitly set, use that
    if [[ "$BACKUP_MODE" == "full" ]]; then
        echo "full"
        return
    elif [[ "$BACKUP_MODE" == "incr" ]]; then
        echo "incr"
        return
    elif [[ "$BACKUP_MODE" == "setup" ]]; then
        echo "full"
        return
    fi

    # Auto mode: determine based on day of week and existing backups
    local day_of_week=$(date +%u)  # 1=Monday, 7=Sunday

    if [[ "$day_of_week" == "7" ]] || [[ "$FORCE_FULL_BACKUP" == "true" ]]; then
        # Sunday or forced full backup
        echo "full"
    else
        # Monday-Saturday: check if we have a recent full backup
        local has_recent_full
        has_recent_full=$(sudo -u postgres pgbackrest --stanza=$STANZA_NAME info --output=json 2>/dev/null | grep -q '"type":"full"' && echo 'true' || echo 'false')

        if [[ "$has_recent_full" == "true" ]]; then
            echo "incr"
        else
            log_warning "No recent full backup found, taking full backup instead of incremental" >&2
            echo "full"
        fi
    fi
}

should_run_setup() {
    # Check if this is the first run (setup mode)
    if [[ "$BACKUP_MODE" == "setup" ]]; then
        return 0
    fi

    # In scheduled mode, never run setup
    if [[ "$SCHEDULED_MODE" == "true" ]]; then
        return 1
    fi

    # Check if already configured
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        if [[ "${PGBACKREST_CONFIGURED:-false}" == "true" ]] && [[ "${INITIAL_BACKUP_COMPLETED:-false}" == "true" ]]; then
            return 1  # Setup already completed
        fi
    fi

    return 0  # Needs setup
}

#===============================================================================
# Prerequisites Check - Standby Specific
#===============================================================================

check_prerequisites() {
    log "Checking prerequisites for standby backup setup..."

    # Check required commands
    check_command "aws"
    check_command "nc"

    # Check AWS CLI configuration
    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS CLI not configured properly"
        exit 1
    fi

    # Verify this server's IP matches the configured standby IP
    log_info "Verifying server IP configuration..."
    local current_ip=$(get_current_server_ip)

    if [[ -z "$current_ip" ]]; then
        log_error "Could not determine current server's IP address"
        exit 1
    fi

    log_info "Current server IP: $current_ip"
    log_info "Expected standby IP: $STANDBY_IP"

    if [[ "$current_ip" != "$STANDBY_IP" ]]; then
        log_error "This script is configured to run on $STANDBY_IP but is running on $current_ip"
        log_error "Please either:"
        log_error "  1. Run this script on server $STANDBY_IP"
        log_error "  2. Or set STANDBY_IP environment variable:"
        log_error "     export STANDBY_IP='$current_ip'"
        log_error "     ./pgbackrest_standby_backup_setup.sh"
        exit 1
    fi

    log_success "Server IP verified: running on correct standby server ($current_ip)"

    # Verify this is actually a standby server
    log_info "Verifying this server is a standby in the repmgr cluster..."

    # First check if PostgreSQL is in recovery mode
    local in_recovery=$(sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | xargs)
    if [[ "$in_recovery" != "t" ]]; then
        log_error "Server is not in recovery mode. This script is only for standby servers."
        log_error "For primary servers, use pgbackrest_primary_setup.sh instead."
        exit 1
    fi

    # Check repmgr status if available
    if [ -f "$REPMGR_BIN" ]; then
        local node_role=$(sudo -u postgres $REPMGR_BIN -f /var/lib/pgsql/repmgr.conf node status 2>/dev/null | grep "Role:" | awk '{print $NF}')
        if [[ "$node_role" != "standby" ]]; then
            log_error "This server is not a standby according to repmgr (role: $node_role)"
            exit 1
        fi
    fi

    # Check SSH connectivity to primary for pgBackRest
    log_info "Checking SSH connectivity to primary server..."
    if ! sudo -u postgres ssh -o BatchMode=yes -o ConnectTimeout=5 postgres@$PRIMARY_IP 'exit 0' 2>/dev/null; then
        log_error "Cannot SSH to primary server as postgres user"
        log_error "Please ensure passwordless SSH is configured from standby to primary"
        log_error "Run: sudo -u postgres ssh-copy-id postgres@$PRIMARY_IP"
        exit 1
    fi

    log_success "Prerequisites check completed - server confirmed as standby"
}

#===============================================================================
# Step 1: Setup Backup Volume on Standby
#===============================================================================

setup_backup_volume() {
    log "=== STEP 1: Setting up backup volume on standby ==="

    # Check if mount point already exists and is mounted
    if mount | grep -q "$BACKUP_MOUNT_POINT"; then
        log_info "Backup mount point already exists"

        # Check if it has the required structure
        if [ -d "$BACKUP_MOUNT_POINT/repo" ] && [ -d "$BACKUP_MOUNT_POINT/logs" ]; then
            log_info "Existing backup directory structure found - using existing setup"
        else
            log_info "Creating missing directory structure"
            sudo -u postgres mkdir -p $BACKUP_MOUNT_POINT/{repo,logs,archive}
        fi
    else
        log_info "No backup mount point found - checking for available devices"

        # Check if backup device exists but is not mounted
        if lsblk | grep -q "${BACKUP_DEVICE##*/}"; then
            log_info "Backup device ${BACKUP_DEVICE##*/} found - mounting it"

            # Check if volume needs formatting
            if ! sudo file -s $BACKUP_DEVICE | grep -q 'ext4'; then
                log_info "Formatting backup device..."
                sudo mkfs.ext4 $BACKUP_DEVICE
            fi

            # Create mount point and mount
            sudo mkdir -p $BACKUP_MOUNT_POINT
            sudo mount $BACKUP_DEVICE $BACKUP_MOUNT_POINT

            # Add to fstab for persistence
            if ! grep -q "$BACKUP_DEVICE" /etc/fstab; then
                echo "$BACKUP_DEVICE $BACKUP_MOUNT_POINT ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
            fi
        else
            # No device found - create and attach EBS volume if AWS credentials available
            log_warning "No dedicated backup device found"

            if aws sts get-caller-identity &>/dev/null; then
                log_info "AWS credentials available - creating EBS volume for backups"

                # Get instance details using IMDSv2 (token required)
                local imds_token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
                local instance_id=$(curl -s -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
                local az=$(curl -s -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null)

                if [[ -n "$instance_id" ]] && [[ -n "$az" ]]; then
                    log_info "Creating ${DEFAULT_BACKUP_VOLUME_SIZE}GB EBS volume in $az..."

                    # Create volume
                    local volume_id=$(aws ec2 create-volume \
                        --size "$DEFAULT_BACKUP_VOLUME_SIZE" \
                        --volume-type "gp3" \
                        --availability-zone "$az" \
                        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=pgbackrest-backup-$instance_id},{Key=Purpose,Value=pgbackrest-backup}]" \
                        --query 'VolumeId' \
                        --output text \
                        --region "$AWS_REGION" 2>/dev/null)

                    if [[ -n "$volume_id" ]] && [[ "$volume_id" != "None" ]]; then
                        log_success "Created volume: $volume_id"

                        # Wait for volume
                        aws ec2 wait volume-available --volume-ids "$volume_id" --region "$AWS_REGION"

                        # Attach volume
                        aws ec2 attach-volume \
                            --volume-id "$volume_id" \
                            --instance-id "$instance_id" \
                            --device "$BACKUP_DEVICE" \
                            --region "$AWS_REGION"

                        # Wait for attachment
                        log_info "Waiting for volume to attach..."
                        aws ec2 wait volume-in-use --volume-ids "$volume_id" --region "$AWS_REGION"

                        # Wait for device to appear
                        local device_path=""
                        for i in {1..30}; do
                            if [[ -b "$BACKUP_DEVICE" ]]; then
                                device_path="$BACKUP_DEVICE"
                                break
                            elif [[ -b "/dev/nvme1n1" ]]; then
                                device_path="/dev/nvme1n1"
                                BACKUP_DEVICE="/dev/nvme1n1"
                                break
                            fi
                            sleep 2
                        done

                        if [[ -n "$device_path" ]]; then
                            log_success "Device available at: $device_path"

                            # Format and mount
                            sudo mkfs.ext4 "$device_path"
                            sudo mkdir -p $BACKUP_MOUNT_POINT
                            sudo mount "$device_path" $BACKUP_MOUNT_POINT

                            # Add to fstab
                            local uuid=$(sudo blkid -s UUID -o value "$device_path")
                            echo "UUID=$uuid $BACKUP_MOUNT_POINT ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
                        else
                            log_error "Device did not appear after 60 seconds"
                            log_error ""
                            log_error "=========================================="
                            log_error "DEDICATED BACKUP VOLUME REQUIRED"
                            log_error "=========================================="
                            log_error "Please attach an EBS volume and mount it at: $BACKUP_MOUNT_POINT"
                            log_error "Then re-run this script."
                            log_error ""
                            log_error "Example commands:"
                            log_error "  sudo mkfs.ext4 /dev/nvmeXn1"
                            log_error "  sudo mkdir -p $BACKUP_MOUNT_POINT"
                            log_error "  sudo mount /dev/nvmeXn1 $BACKUP_MOUNT_POINT"
                            log_error "=========================================="
                            exit 1
                        fi
                    else
                        log_error "Failed to create EBS volume"
                        log_error ""
                        log_error "=========================================="
                        log_error "DEDICATED BACKUP VOLUME REQUIRED"
                        log_error "=========================================="
                        log_error "Please attach an EBS volume and mount it at: $BACKUP_MOUNT_POINT"
                        log_error "Then re-run this script."
                        log_error "=========================================="
                        exit 1
                    fi
                else
                    log_error "Could not get instance metadata"
                    log_error ""
                    log_error "=========================================="
                    log_error "DEDICATED BACKUP VOLUME REQUIRED"
                    log_error "=========================================="
                    log_error "EBS snapshots require a dedicated backup volume."
                    log_error "Please attach an EBS volume and mount it at: $BACKUP_MOUNT_POINT"
                    log_error ""
                    log_error "Example commands after attaching EBS volume:"
                    log_error "  sudo mkfs.ext4 /dev/nvmeXn1"
                    log_error "  sudo mkdir -p $BACKUP_MOUNT_POINT"
                    log_error "  sudo mount /dev/nvmeXn1 $BACKUP_MOUNT_POINT"
                    log_error "  sudo chown postgres:postgres $BACKUP_MOUNT_POINT"
                    log_error ""
                    log_error "Then re-run this script."
                    log_error "=========================================="
                    exit 1
                fi
            else
                log_warning "No AWS credentials available to create EBS volume"
                log_error ""
                log_error "=========================================="
                log_error "DEDICATED BACKUP VOLUME REQUIRED"
                log_error "=========================================="
                log_error "EBS snapshots require a dedicated backup volume."
                log_error "Please attach an EBS volume and mount it at: $BACKUP_MOUNT_POINT"
                log_error ""
                log_error "Example commands after attaching EBS volume:"
                log_error "  sudo mkfs.ext4 /dev/nvmeXn1"
                log_error "  sudo mkdir -p $BACKUP_MOUNT_POINT"
                log_error "  sudo mount /dev/nvmeXn1 $BACKUP_MOUNT_POINT"
                log_error "  sudo chown postgres:postgres $BACKUP_MOUNT_POINT"
                log_error ""
                log_error "Then re-run this script."
                log_error "=========================================="
                exit 1
            fi
        fi

        # Set permissions and create directory structure
        sudo chown -R postgres:postgres $BACKUP_MOUNT_POINT
        sudo chmod 750 $BACKUP_MOUNT_POINT
        sudo -u postgres mkdir -p $BACKUP_MOUNT_POINT/{repo,logs,archive}
    fi

    # Verify setup
    df -h $BACKUP_MOUNT_POINT
    ls -la $BACKUP_MOUNT_POINT/

    save_state "BACKUP_VOLUME_CONFIGURED" "true"
    log_success "Backup volume setup completed"
}

#===============================================================================
# Primary Server Configuration Management
#===============================================================================

get_next_available_repo_number() {
    # Check primary's pgBackRest config to find next available repo number
    local primary_ip="$1"
    local max_repo=0

    # Get existing repo configurations from primary
    local primary_config=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 postgres@$primary_ip "cat /etc/pgbackrest/pgbackrest.conf 2>/dev/null" 2>/dev/null || echo "")

    if [[ -n "$primary_config" ]]; then
        # Find all repo configurations (repo1, repo2, etc.)
        local repo_nums=$(echo "$primary_config" | grep -oE '^repo[0-9]+-' | grep -oE '[0-9]+' | sort -n | uniq)

        if [[ -n "$repo_nums" ]]; then
            max_repo=$(echo "$repo_nums" | tail -1)
        fi
    fi

    # Return next available number
    echo $((max_repo + 1))
}

find_repo_for_standby() {
    # Check if this standby already has a repo configured on primary
    local primary_ip="$1"
    local standby_ip="$2"

    local primary_config=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 postgres@$primary_ip "cat /etc/pgbackrest/pgbackrest.conf 2>/dev/null" 2>/dev/null || echo "")

    if [[ -n "$primary_config" ]]; then
        # Check each repo to see if it points to our standby
        for i in {1..10}; do
            if echo "$primary_config" | grep -q "repo${i}-host=$standby_ip"; then
                echo "$i"
                return
            fi
        done
    fi

    echo "0"  # Not found
}

# Function to ensure archive_mode is enabled on primary
ensure_archive_mode_enabled() {
    log_info "Checking archive_mode on primary..."

    local current_archive_mode=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "psql -t -c 'show archive_mode;' 2>/dev/null" | xargs)

    if [[ "$current_archive_mode" != "on" ]]; then
        log_warning "archive_mode is '$current_archive_mode' on primary - enabling it (requires restart)"
        ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "psql -c \"ALTER SYSTEM SET archive_mode = on;\""

        # Also set archive_command before restart
        log_info "Setting archive_command on primary"
        ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "psql -c \"ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=$STANZA_NAME archive-push %p';\""

        # Restart PostgreSQL on primary to apply archive_mode
        log_warning "Restarting PostgreSQL on primary to enable archive_mode..."
        ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "pg_ctl -D $PG_DATA_DIR restart -m fast -w" || {
            log_error "Failed to restart PostgreSQL on primary via pg_ctl"
            log_info "Trying systemctl restart..."
            ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "sudo systemctl restart postgresql" || true
        }

        # Wait for primary to come back up
        log_info "Waiting for primary PostgreSQL to start..."
        sleep 3
        local retries=0
        while ! ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "pg_isready" &>/dev/null; do
            retries=$((retries + 1))
            if [[ $retries -gt 30 ]]; then
                log_error "Primary PostgreSQL did not start within 30 seconds"
                return 1
            fi
            sleep 1
        done
        log_success "PostgreSQL restarted on primary with archive_mode enabled"
    else
        log_info "archive_mode already enabled on primary"

        # Still check archive_command
        local current_archive_cmd=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "psql -t -c 'show archive_command;' 2>/dev/null" | xargs)
        if [[ ! "$current_archive_cmd" =~ "pgbackrest" ]]; then
            log_info "Updating PostgreSQL archive_command on primary"
            ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "psql -c \"ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=$STANZA_NAME archive-push %p';\" && \
                                       psql -c 'SELECT pg_reload_conf();'"
        fi
    fi
}

configure_primary_for_s3() {
    log_info "Configuring PRIMARY server for S3 WAL archiving..."

    # Create directories on primary
    ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "
        mkdir -p /etc/pgbackrest /var/log/pgbackrest 2>/dev/null || true
    " || true

    # Check if primary has S3 access
    log_info "Checking S3 access from primary server..."
    local s3_check=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "aws s3 ls s3://${S3_BUCKET}/ --region $S3_REGION 2>&1 | head -1" || echo "failed")

    if [[ "$s3_check" == *"failed"* ]] || [[ "$s3_check" == *"error"* ]] || [[ "$s3_check" == *"AccessDenied"* ]]; then
        log_error "PRIMARY server cannot access S3 bucket: $S3_BUCKET"
        log_error "Please ensure the PRIMARY server has an IAM role with S3 permissions"
        log_error "Required permissions: s3:ListBucket, s3:GetObject, s3:PutObject, s3:DeleteObject"
        return 1
    fi
    log_success "PRIMARY server has S3 access"

    # Create pgbackrest config for S3 on primary
    log_info "Creating pgBackRest S3 configuration on primary..."
    ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "cat > /etc/pgbackrest/pgbackrest.conf << 'PGBREOF'
[$STANZA_NAME]
pg1-path=$PG_DATA_DIR
pg1-port=5432
pg1-socket-path=/tmp

[global]
repo1-type=s3
repo1-s3-bucket=$S3_BUCKET
repo1-s3-region=$S3_REGION
repo1-s3-endpoint=s3.${S3_REGION}.amazonaws.com
repo1-s3-key-type=auto
repo1-path=/pgbackrest/${STANZA_NAME}
repo1-retention-full=4
repo1-retention-diff=7
repo1-retention-archive=14

log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest

start-fast=y
stop-auto=y
compress-type=zst
compress-level=3
PGBREOF"

    log_success "pgBackRest S3 configuration created on primary"

    # Verify pgbackrest can connect to S3 from primary
    log_info "Verifying pgBackRest S3 access from primary..."
    local verify_result=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "pgbackrest --stanza=$STANZA_NAME info 2>&1" || echo "")

    if [[ "$verify_result" == *"ERROR"* ]] && [[ "$verify_result" != *"stanza"* ]]; then
        log_warning "pgBackRest info returned warning (stanza may not exist yet - this is OK)"
    fi

    # Force a WAL switch to test archiving
    log_info "Testing WAL archiving to S3 from primary..."
    ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "psql -c 'SELECT pg_switch_wal();'" || true

    # Wait for archive
    sleep 3

    # Check if WAL was archived to S3
    local wal_check=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "aws s3 ls s3://${S3_BUCKET}/pgbackrest/${STANZA_NAME}/archive/ --recursive --region $S3_REGION 2>&1 | tail -3" || echo "")

    if [[ -n "$wal_check" ]] && [[ "$wal_check" != *"error"* ]]; then
        log_success "WAL archiving to S3 is working from primary"
        log_info "Recent WAL files in S3:"
        echo "$wal_check"
    else
        log_warning "WAL may not be archived yet - will be archived on next checkpoint"
    fi

    save_state "PRIMARY_S3_CONFIGURED" "true"
    log_success "Primary server configured for S3 WAL archiving"
}

configure_primary_for_multi_repo() {
    log_info "Configuring primary server for multi-repository setup..."

    # If using S3 storage, configure primary for S3
    if [[ "$STORAGE_TYPE" == "s3" ]]; then
        configure_primary_for_s3
        save_state "STANDBY_REPO_NUMBER" "1"
        ensure_archive_mode_enabled
        return 0
    fi

    local standby_ip=$(get_current_server_ip)
    local existing_repo=$(find_repo_for_standby "$PRIMARY_IP" "$standby_ip")

    if [[ "$existing_repo" != "0" ]]; then
        log_info "This standby already configured as repo$existing_repo on primary"
        save_state "STANDBY_REPO_NUMBER" "$existing_repo"

        # Still need to ensure archive_mode is enabled on primary
        ensure_archive_mode_enabled
        return 0
    fi

    # Get next available repo number
    local repo_num=$(get_next_available_repo_number "$PRIMARY_IP")
    log_info "Configuring this standby as repo$repo_num on primary"

    # Get current primary config
    local primary_config=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 postgres@$PRIMARY_IP "cat /etc/pgbackrest/pgbackrest.conf 2>/dev/null" || echo "")

    # Check if we need to create a new config or append to existing
    if [[ -z "$primary_config" ]] || ! echo "$primary_config" | grep -q "\[global\]"; then
        # Create new configuration
        local repo_path="/backup/pgbackrest/repo"
        local standby_ip="$STANDBY_IP"
        log_info "Creating new pgBackRest configuration on primary"
        # Create directory on primary if not exists
        ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "mkdir -p /etc/pgbackrest && chmod 750 /etc/pgbackrest"
        ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "cat > /etc/pgbackrest/pgbackrest.conf" << EOF
[$STANZA_NAME]
pg1-path=$PG_DATA_DIR
pg1-port=5432
pg1-socket-path=/tmp

[global]
# Repository $repo_num - Standby at $standby_ip
repo${repo_num}-host-user=postgres
repo${repo_num}-host=$standby_ip
repo${repo_num}-path=$repo_path
repo${repo_num}-retention-full=4
repo${repo_num}-retention-diff=3
repo${repo_num}-retention-archive=10

process-max=12
start-fast=y
stop-auto=y
delta=y
compress-type=zst
compress-level=3
log-level-console=info
log-level-file=detail
log-path=/backup/pgbackrest/logs
EOF
    else
        # Append new repository to existing config
        log_info "Adding repository configuration to existing primary config"

        # Create a temporary file with the new repo config
        local new_repo_config="
# Repository $repo_num - Standby at $standby_ip
repo${repo_num}-host-user=postgres
repo${repo_num}-host=$standby_ip
repo${repo_num}-path=$repo_path
repo${repo_num}-retention-full=4
repo${repo_num}-retention-diff=3
repo${repo_num}-retention-archive=10"

        # Insert the new repo config into the [global] section
        ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "cp /etc/pgbackrest/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf.bak && \
            awk '/^\[global\]/ {print; print \"$new_repo_config\"; next} {print}' /etc/pgbackrest/pgbackrest.conf.bak > /etc/pgbackrest/pgbackrest.conf"
    fi

    # Verify configuration
    log_info "Verifying primary configuration..."
    ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "pgbackrest --stanza=$STANZA_NAME --repo=$repo_num check 2>&1" || true

    save_state "STANDBY_REPO_NUMBER" "$repo_num"
    log_success "Primary configured with repo$repo_num for this standby"

    # Ensure archive_mode is enabled on primary
    ensure_archive_mode_enabled
}

#===============================================================================
# Step 2: Install and Configure pgBackRest on Standby
#===============================================================================

configure_pgbackrest_standby() {
    log "=== STEP 2: Configuring pgBackRest on standby ==="

    # Install pgBackRest if not already installed
    if ! command -v pgbackrest &> /dev/null; then
        log_info "Installing pgBackRest..."

        # Detect package manager
        if command -v dnf &> /dev/null; then
            PKG_MGR="dnf"
        else
            PKG_MGR="yum"
        fi

        # Install build dependencies
        sudo $PKG_MGR install -y gcc openssl-devel \
            libxml2-devel lz4-devel libzstd-devel bzip2-devel libyaml-devel \
            python3-pip wget || true

        # Try to install postgresql-devel
        sudo $PKG_MGR install -y postgresql${PG_VERSION}-devel 2>/dev/null || \
        sudo $PKG_MGR install -y postgresql-devel 2>/dev/null || true

        # Install meson and ninja
        sudo pip3 install meson ninja || sudo pip install meson ninja

        # Download and build pgBackRest
        cd /tmp
        wget -O - https://github.com/pgbackrest/pgbackrest/archive/release/2.55.1.tar.gz | tar zx
        cd pgbackrest-release-2.55.1
        meson setup build
        ninja -C build
        sudo cp build/src/pgbackrest /usr/bin/
        sudo chmod 755 /usr/bin/pgbackrest
        pgbackrest version

        # Cleanup
        cd /
        rm -rf /tmp/pgbackrest-release-2.55.1
    else
        log_info "pgBackRest already installed"
        pgbackrest version
    fi

    # Create pgBackRest directories
    sudo mkdir -p /etc/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest
    sudo chown postgres:postgres /etc/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest

    # Configure primary server for multi-repository setup
    configure_primary_for_multi_repo

    # Get the repository number assigned to this standby
    local repo_num="${STANDBY_REPO_NUMBER:-1}"

    # Read the actual repo path from primary config for EBS
    local repo_path=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "grep -E \"^repo${repo_num}-path=\" /etc/pgbackrest/pgbackrest.conf | cut -d= -f2" 2>/dev/null | tr -d " ")
    if [[ -z "$repo_path" ]]; then
        repo_path="$BACKUP_MOUNT_POINT/repo${repo_num}"
    fi
    log_info "Using repo path from primary: $repo_path"

    # Create the repo directory for this standby (for EBS storage)
    if [[ "$STORAGE_TYPE" == "ebs" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
        sudo -u postgres mkdir -p $repo_path
    fi

    # Configure pgBackRest based on storage type
    log_info "Creating pgBackRest configuration for standby backup (storage: $STORAGE_TYPE)..."

    case "$STORAGE_TYPE" in
        "ebs")
            # EBS-only configuration
            sudo -u postgres tee /etc/pgbackrest/pgbackrest.conf << EOF
[$STANZA_NAME]
# Local standby server
pg1-path=$PG_DATA_DIR
pg1-port=5432
pg1-socket-path=/tmp

# Primary server (required for standby backups)
pg2-host=$PRIMARY_IP
pg2-path=$PG_DATA_DIR
pg2-port=5432
pg2-host-user=postgres
pg2-socket-path=/tmp

# Standby-specific settings
backup-standby=y
delta=y

[global]
# Repository 1 - Local EBS storage
repo1-path=$repo_path
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
log-path=$BACKUP_MOUNT_POINT/logs

# Archive settings
archive-get-queue-max=128MB
archive-push-queue-max=128MB
EOF
            ;;

        "s3")
            # S3-only configuration
            sudo -u postgres tee /etc/pgbackrest/pgbackrest.conf << EOF
[$STANZA_NAME]
# Local standby server
pg1-path=$PG_DATA_DIR
pg1-port=5432
pg1-socket-path=/tmp

# Primary server (required for standby backups)
pg2-host=$PRIMARY_IP
pg2-path=$PG_DATA_DIR
pg2-port=5432
pg2-host-user=postgres
pg2-socket-path=/tmp

# Standby-specific settings
backup-standby=y
delta=y

[global]
# Repository 1 - S3 storage
repo1-type=s3
repo1-s3-bucket=$S3_BUCKET
repo1-s3-region=$S3_REGION
repo1-s3-endpoint=s3.${S3_REGION}.amazonaws.com
repo1-s3-key-type=auto
repo1-path=/pgbackrest/${STANZA_NAME}
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
EOF
            ;;

        "both")
            # Both EBS and S3 configuration
            sudo -u postgres tee /etc/pgbackrest/pgbackrest.conf << EOF
[$STANZA_NAME]
# Local standby server
pg1-path=$PG_DATA_DIR
pg1-port=5432
pg1-socket-path=/tmp

# Primary server (required for standby backups)
pg2-host=$PRIMARY_IP
pg2-path=$PG_DATA_DIR
pg2-port=5432
pg2-host-user=postgres
pg2-socket-path=/tmp

# Standby-specific settings
backup-standby=y
delta=y

[global]
# Repository 1 - Local EBS storage (fast recovery)
repo1-path=$repo_path
repo1-retention-full=2
repo1-retention-diff=7
repo1-retention-archive=7

# Repository 2 - S3 storage (disaster recovery)
repo2-type=s3
repo2-s3-key-type=auto
repo2-s3-bucket=$S3_BUCKET
repo2-s3-region=$S3_REGION
repo2-s3-endpoint=s3.${S3_REGION}.amazonaws.com
repo2-path=/pgbackrest/${STANZA_NAME}
repo2-retention-full=4
repo2-retention-diff=14
repo2-retention-archive=30

process-max=8
start-fast=y
stop-auto=y
compress-type=zst
compress-level=3
log-level-console=info
log-level-file=detail
log-path=$BACKUP_MOUNT_POINT/logs

# Archive settings
archive-get-queue-max=128MB
archive-push-queue-max=128MB
EOF
            ;;
    esac

    save_state "PGBACKREST_CONFIGURED" "true"
    save_state "STORAGE_TYPE" "$STORAGE_TYPE"
    log_success "pgBackRest configuration completed (storage: $STORAGE_TYPE)"
}

#===============================================================================
# Step 3: Create Stanza and Take Backup from Standby
#===============================================================================

create_stanza_and_backup() {
    local backup_type=$(determine_backup_type)

    if [[ "$backup_type" == "skip" ]]; then
        log "=== STEP 3: Skipping backup creation (SKIP_BACKUP=true) ==="
        log_info "Using existing backups"

        # Show current backup information
        sudo -u postgres pgbackrest --stanza=$STANZA_NAME info 2>/dev/null || true

        save_state "INITIAL_BACKUP_COMPLETED" "true"
        return
    fi

    log "=== STEP 3: Creating stanza and taking $backup_type backup from standby ==="

    # Get the repository number for this standby
    local repo_num="${STANDBY_REPO_NUMBER:-1}"
    # Read the actual repo path from primary config
    local repo_path=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "grep -E \"^repo${repo_num}-path=\" /etc/pgbackrest/pgbackrest.conf | cut -d= -f2" 2>/dev/null | tr -d " ")
    if [[ -z "$repo_path" ]]; then
        repo_path="$BACKUP_MOUNT_POINT/repo${repo_num}"
    fi
    log_info "Using repo path from primary: $repo_path"

    # Create stanza if it doesn't exist
    log_info "Creating pgBackRest stanza for repo$repo_num..."
    if ! sudo -u postgres pgbackrest --stanza=$STANZA_NAME stanza-create 2>/dev/null; then
        log_info "Stanza already exists or creation skipped"
    fi

    # Get the repository number for this standby
    local repo_num="${STANDBY_REPO_NUMBER:-1}"
    # Read the actual repo path from primary config
    local repo_path=$(ssh -i /var/lib/pgsql/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "grep -E \"^repo${repo_num}-path=\" /etc/pgbackrest/pgbackrest.conf | cut -d= -f2" 2>/dev/null | tr -d " ")
    if [[ -z "$repo_path" ]]; then
        repo_path="$BACKUP_MOUNT_POINT/repo${repo_num}"
    fi
    log_info "Using repo path from primary: $repo_path"

    # Take backup from standby
    log_info "Taking $backup_type backup from standby server (repo$repo_num on primary)..."
    log_warning "Note: Standby backups may take longer than primary backups"

    if sudo -u postgres pgbackrest --stanza=$STANZA_NAME --type=$backup_type backup; then
        log_success "$backup_type backup completed from standby"
    else
        log_error "Backup failed - check pgBackRest logs in $BACKUP_MOUNT_POINT/logs"
        log_error "You may need to check:"
        log_error "  1. WAL archiving is working from primary to this standby"
        log_error "  2. SSH connectivity between primary and standby"
        log_error "  3. Repository permissions on this standby"
        return 1
    fi

    # Verify backup
    log_info "Verifying backup..."
    sudo -u postgres pgbackrest --stanza=$STANZA_NAME info

    save_state "INITIAL_BACKUP_COMPLETED" "true"
    save_state "LAST_BACKUP_TYPE" "$backup_type"
    save_state "LAST_BACKUP_DATE" "\"$(date '+%Y-%m-%d %H:%M:%S')\""
    save_state "BACKUP_FROM_STANDBY" "true"
    save_state "STANZA_NAME" "$STANZA_NAME"
}

#===============================================================================
# Step 4: Create EBS Snapshot of Standby Backup Volume
#===============================================================================

create_ebs_snapshot() {
    if [[ "$SKIP_SNAPSHOT" == "true" ]]; then
        log_info "Snapshot creation skipped (SKIP_SNAPSHOT=true)"
        return 0
    fi

    log "=== STEP 4: Creating EBS snapshot of standby backup volume ==="

    # Check if we're using a dedicated backup device
    local mount_source=$(mount | grep "$BACKUP_MOUNT_POINT" | awk '{print $1}')

    if [[ -z "$mount_source" ]] || [[ ! "$mount_source" =~ ^/dev/ ]]; then
        log_warning "Backup is on root filesystem - cannot create EBS snapshot"
        log_info "Attach a dedicated EBS volume for snapshot capability"
        save_state "SNAPSHOT_AVAILABLE" "false"
        return 0
    fi

    # Get instance ID using IMDSv2
    local token=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
    local instance_id=$(curl -H "X-aws-ec2-metadata-token: $token" -s http://169.254.169.254/latest/meta-data/instance-id)

    if [[ -z "$instance_id" ]]; then
        log_error "Could not retrieve instance ID"
        return 1
    fi

    log_info "Instance ID: $instance_id"

    # Check if volume ID is manually provided (for cases with limited IAM permissions)
    if [[ -n "${MANUAL_BACKUP_VOLUME_ID:-}" ]]; then
        BACKUP_VOLUME_ID="$MANUAL_BACKUP_VOLUME_ID"
        log_info "Using manually provided volume ID: $BACKUP_VOLUME_ID"
    else
        # Get volume ID for the backup device
        BACKUP_VOLUME_ID=$(aws ec2 describe-volumes \
        --filters "Name=attachment.instance-id,Values=$instance_id" \
        --query "Volumes[?Attachments[?Device=='$mount_source']].VolumeId | [0]" \
        --output text \
        --region "$AWS_REGION" 2>/dev/null)

    # Try alternative device mappings if not found
    if [[ "$BACKUP_VOLUME_ID" == "None" ]] || [[ -z "$BACKUP_VOLUME_ID" ]] || [[ "$BACKUP_VOLUME_ID" == "null" ]]; then
        log_info "Direct device lookup failed for $mount_source, trying alternative mappings..."
        for alt_device in "/dev/xvdb" "/dev/sdb" "/dev/nvme1n1"; do
            log_info "Trying AWS device mapping: $alt_device"
            BACKUP_VOLUME_ID=$(aws ec2 describe-volumes \
                --filters "Name=attachment.device,Values=$alt_device" \
                          "Name=attachment.instance-id,Values=$instance_id" \
                --query 'Volumes[0].VolumeId' \
                --output text \
                --region "$AWS_REGION" 2>/dev/null)

            if [[ "$BACKUP_VOLUME_ID" != "None" ]] && [[ -n "$BACKUP_VOLUME_ID" ]] && [[ "$BACKUP_VOLUME_ID" != "null" ]]; then
                log_info "Found backup volume using alternative device mapping: $alt_device -> $BACKUP_VOLUME_ID"
                break
            fi
        done
    fi
    fi

    if [[ "$BACKUP_VOLUME_ID" == "None" ]] || [[ -z "$BACKUP_VOLUME_ID" ]]; then
        log_error "Could not determine backup volume ID"
        return 1
    fi

    log_info "Backup Volume ID: $BACKUP_VOLUME_ID"

    # Create snapshot with standby-specific tags
    local backup_type="${LAST_BACKUP_TYPE:-full}"
    local day_name=$(date +%A)
    local snapshot_desc="pgbackrest-standby-$STANZA_NAME-$backup_type-$(date +%Y%m%d-%H%M%S)"

    SNAPSHOT_ID=$(aws ec2 create-snapshot \
        --volume-id "$BACKUP_VOLUME_ID" \
        --description "$snapshot_desc" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$snapshot_desc},{Key=BackupType,Value=$backup_type},{Key=Stanza,Value=$STANZA_NAME},{Key=Source,Value=standby},{Key=SourceIP,Value=$STANDBY_IP},{Key=Day,Value=$day_name}]" \
        --query 'SnapshotId' \
        --output text \
        --region "$AWS_REGION")

    if [[ -z "$SNAPSHOT_ID" ]] || [[ "$SNAPSHOT_ID" == "None" ]]; then
        log_error "Failed to create snapshot"
        return 1
    fi

    log_info "Snapshot created: $SNAPSHOT_ID"

    # Save snapshot info to state file
    save_state "BACKUP_VOLUME_ID" "$BACKUP_VOLUME_ID"
    save_state "LATEST_SNAPSHOT_ID" "$SNAPSHOT_ID"
    save_state "LAST_SNAPSHOT_DATE" "\"$(date '+%Y-%m-%d %H:%M:%S')\""
    save_state "SNAPSHOT_AVAILABLE" "true"

    # In setup mode, wait for completion
    if [[ "$BACKUP_MODE" == "setup" ]] || [[ "$SCHEDULED_MODE" == "false" ]]; then
        log "Waiting for snapshot to complete..."
        aws ec2 wait snapshot-completed --snapshot-ids "$SNAPSHOT_ID" --region "$AWS_REGION"
        log_success "Snapshot completed: $SNAPSHOT_ID"
    else
        log_info "Snapshot creation initiated: $SNAPSHOT_ID (completion in background)"
    fi

    # Cleanup old snapshots if enabled
    if [[ "$CLEANUP_OLD_SNAPSHOTS" == "true" ]]; then
        cleanup_old_snapshots
    fi
}

#===============================================================================
# Step 5: Cleanup Old Snapshots
#===============================================================================

cleanup_old_snapshots() {
    if [[ "$CLEANUP_OLD_SNAPSHOTS" != "true" ]]; then
        return 0
    fi

    log "=== Cleaning up old standby snapshots ==="

    # Keep only last 7 days of daily snapshots
    local retention_days=7
    local cutoff_date=$(date -d "${retention_days} days ago" '+%Y-%m-%d')

    local old_snapshots=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:Source,Values=standby" \
                  "Name=tag:Stanza,Values=${STANZA_NAME}" \
        --query "Snapshots[?StartTime<='${cutoff_date}'].SnapshotId" \
        --output text \
        --region "$AWS_REGION" 2>/dev/null)

    local deleted_count=0
    for snapshot in $old_snapshots; do
        if [ -n "$snapshot" ] && [ "$snapshot" != "None" ]; then
            log_info "Deleting old snapshot: $snapshot"
            if aws ec2 delete-snapshot --snapshot-id "$snapshot" --region "$AWS_REGION" 2>/dev/null; then
                ((deleted_count++))
            fi
        fi
    done

    # Keep only last 4 weekly full backups
    if [[ "$(date +%u)" == "7" ]]; then  # Sunday
        local old_weekly=$(aws ec2 describe-snapshots \
            --owner-ids self \
            --filters "Name=tag:Source,Values=standby" \
                      "Name=tag:BackupType,Values=full" \
                      "Name=tag:Stanza,Values=${STANZA_NAME}" \
            --query "Snapshots | sort_by(@, &StartTime) | [:-4].SnapshotId" \
            --output text \
            --region "$AWS_REGION" 2>/dev/null)

        for snapshot in $old_weekly; do
            if [ -n "$snapshot" ] && [ "$snapshot" != "None" ]; then
                log_info "Deleting old weekly snapshot: $snapshot"
                if aws ec2 delete-snapshot --snapshot-id "$snapshot" --region "$AWS_REGION" 2>/dev/null; then
                    ((deleted_count++))
                fi
            fi
        done
    fi

    if [ $deleted_count -gt 0 ]; then
        log_success "Cleaned up $deleted_count old snapshots"
    else
        log_info "No old snapshots to clean up"
    fi
}

#===============================================================================
# Setup Periodic Snapshots
#===============================================================================

setup_periodic_snapshots() {
    log "=== Setting up periodic snapshots from standby ==="

    if [[ "$SETUP_PERIODIC_SNAPSHOTS" != "true" ]]; then
        log_info "Periodic snapshots disabled"
        return 0
    fi

    # Create scheduled backup script
    cat > "${SCRIPT_DIR}/scheduled_standby_backup.sh" << 'EOF'
#!/bin/bash
# Scheduled standby backup wrapper script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/pgbackrest_standby_backup_state.env"

# Source the state file to get configuration
if [ -f "${STATE_FILE}" ]; then
    source "${STATE_FILE}"
fi

# Set environment variables for scheduled execution
export BACKUP_MODE="auto"
export CLEANUP_OLD_SNAPSHOTS="true"

# Log file with date
LOG_FILE="/var/log/pgbackrest_standby_scheduled_$(date +%Y%m%d_%H%M%S).log"

echo "$(date): Starting scheduled standby backup execution" | tee -a "$LOG_FILE"

# Execute the main script
"${SCRIPT_DIR}/pgbackrest_standby_backup_setup.sh" --scheduled >> "$LOG_FILE" 2>&1

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "$(date): Scheduled standby backup completed successfully" | tee -a "$LOG_FILE"
else
    echo "$(date): Scheduled standby backup failed with exit code $EXIT_CODE" | tee -a "$LOG_FILE"
fi

exit $EXIT_CODE
EOF

    chmod +x "${SCRIPT_DIR}/scheduled_standby_backup.sh"

    log_info "Scheduled backup script created: ${SCRIPT_DIR}/scheduled_standby_backup.sh"
    log_info ""
    log_info "To enable automatic backups from standby, add to crontab:"
    log_info "  # Daily backup from standby at 3 AM (full on Sunday, incremental Mon-Sat)"
    log_info "  0 3 * * * ${SCRIPT_DIR}/scheduled_standby_backup.sh"

    save_state "PERIODIC_SNAPSHOTS_CONFIGURED" "true"
    log_success "Periodic snapshot setup completed"
}

#===============================================================================
# Summary
#===============================================================================

show_summary() {
    log "=== STANDBY BACKUP SETUP COMPLETED SUCCESSFULLY! ==="
    echo
    log_info "=== CONFIGURATION SUMMARY ==="
    log_info "Primary Server: $PRIMARY_IP"
    log_info "Standby Server: $STANDBY_IP (this server)"
    log_info "PostgreSQL Version: $PG_VERSION"
    log_info "Data Directory: $PG_DATA_DIR"
    log_info "Stanza Name: $STANZA_NAME"
    log_info "Storage Type: $STORAGE_TYPE"

    if [[ "$STORAGE_TYPE" == "ebs" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
        log_info "EBS Backup Location: $BACKUP_MOUNT_POINT"
        if [ -n "${BACKUP_VOLUME_ID:-}" ]; then
            log_info "Backup Volume: $BACKUP_VOLUME_ID"
        fi
        if [ -n "${SNAPSHOT_ID:-}" ]; then
            log_info "Latest Snapshot: $SNAPSHOT_ID"
        fi
    fi

    if [[ "$STORAGE_TYPE" == "s3" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
        log_info "S3 Bucket: $S3_BUCKET"
        log_info "S3 Region: $S3_REGION"
        log_info "S3 Path: /pgbackrest/${STANZA_NAME}"
    fi

    echo
    log_info "=== REPMGR CLUSTER STATUS ==="
    # Try to find repmgr config file
    local repmgr_conf="/var/lib/pgsql/repmgr.conf"
    if [ ! -f "$repmgr_conf" ]; then
        repmgr_conf="/etc/repmgr.conf"
    fi
    if [ -f "$REPMGR_BIN" ] && [ -f "$repmgr_conf" ]; then
        sudo -u postgres $REPMGR_BIN -f "$repmgr_conf" cluster show 2>/dev/null || log_info "repmgr cluster show failed"
    else
        log_info "repmgr not available for cluster status"
    fi

    echo
    log_info "=== STATE FILE ==="
    log_info "Configuration saved to: $STATE_FILE"
    log_info "This file is needed for pgbackrest_standby_setup.sh"
    echo
    log_info "=== NEXT STEPS ==="

    if [[ "$STORAGE_TYPE" == "ebs" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
        log_info "1. Use EBS snapshot to create new standbys:"
        log_info "   ./pgbackrest_standby_setup.sh --state-file $STATE_FILE"
        echo
    fi

    if [[ "$STORAGE_TYPE" == "s3" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
        log_info "1. Restore from S3 backup:"
        log_info "   sudo -u postgres pgbackrest --stanza=$STANZA_NAME restore"
        echo
    fi

    log_info "2. Enable scheduled backups (optional):"
    log_info "   echo '0 3 * * * ${SCRIPT_DIR}/scheduled_standby_backup.sh' | crontab -"
    echo

    log_info "3. Monitor backup status:"
    log_info "   sudo -u postgres pgbackrest --stanza=$STANZA_NAME info"
    echo

    log_info "=== IMPORTANT NOTES ==="
    log_info "- Backups are taken from standby to reduce primary load"
    log_info "- Standby backups may take longer than primary backups"

    if [[ "$STORAGE_TYPE" == "ebs" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
        log_info "- EBS snapshots are tagged with 'Source=standby' for identification"
        log_info "- Snapshots can be used to quickly create new standby servers"
    fi

    if [[ "$STORAGE_TYPE" == "s3" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
        log_info "- S3 backups provide durable, off-site storage"
        log_info "- S3 path: s3://${S3_BUCKET}/pgbackrest/${STANZA_NAME}"
    fi

    echo
    log_success "Log saved to: $LOG_FILE"
}

#===============================================================================
# Usage Information
#===============================================================================

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "This script sets up pgBackRest backups on a STANDBY server with support"
    echo "for EBS snapshots, S3 storage, or both."
    echo
    echo "Options:"
    echo "  --scheduled         Run in scheduled/cron mode (non-interactive)"
    echo "  --storage-type TYPE Set storage type: ebs, s3, or both"
    echo "  --s3-bucket NAME    S3 bucket name (required for s3/both storage)"
    echo "  --help              Show this help message"
    echo
    echo "Environment Variables:"
    echo "  PRIMARY_IP          Primary server IP (default: $DEFAULT_PRIMARY_IP)"
    echo "  STANDBY_IP          Standby IP where backups run (default: $DEFAULT_STANDBY_IP)"
    echo "  PG_VERSION          PostgreSQL version (default: $DEFAULT_PG_VERSION)"
    echo "  STANZA_NAME         pgBackRest stanza name (default: $DEFAULT_STANZA_NAME)"
    echo "  AWS_REGION          AWS region (default: $DEFAULT_AWS_REGION)"
    echo "  CUSTOM_DATA_DIR     Custom PostgreSQL data directory (default: $DEFAULT_CUSTOM_DATA_DIR)"
    echo
    echo "Storage Configuration:"
    echo "  STORAGE_TYPE        ebs, s3, or both (default: $DEFAULT_STORAGE_TYPE)"
    echo "  S3_BUCKET           S3 bucket name for backups"
    echo "  S3_REGION           S3 bucket region (default: $DEFAULT_S3_REGION)"
    echo
    echo "Backup Control:"
    echo "  BACKUP_MODE         auto, full, incr, skip (default: auto)"
    echo "  FORCE_FULL_BACKUP   Force full backup (default: false)"
    echo "  SKIP_BACKUP         Skip backup, only snapshot (default: false)"
    echo "  SKIP_SNAPSHOT       Skip snapshot creation (default: false)"
    echo
    echo "Examples:"
    echo "  # Initial setup with interactive storage selection"
    echo "  $0"
    echo
    echo "  # Setup with EBS storage"
    echo "  STORAGE_TYPE=ebs $0"
    echo
    echo "  # Setup with S3 storage"
    echo "  STORAGE_TYPE=s3 S3_BUCKET=my-backup-bucket $0"
    echo
    echo "  # Setup with both EBS and S3"
    echo "  STORAGE_TYPE=both S3_BUCKET=my-backup-bucket $0"
    echo
    echo "  # Scheduled execution (for cron)"
    echo "  $0 --scheduled"
    echo
    echo "  # Force full backup"
    echo "  FORCE_FULL_BACKUP=true $0"
    echo
    echo "After running this script, use the created snapshots with:"
    echo "  ./pgbackrest_standby_setup.sh --state-file $STATE_FILE"
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
    local scheduled_mode=false
    local interactive_mode=true

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --scheduled)
                scheduled_mode=true
                interactive_mode=false
                SCHEDULED_MODE=true
                BACKUP_MODE="${BACKUP_MODE:-auto}"
                shift
                ;;
            --storage-type)
                STORAGE_TYPE="$2"
                STORAGE_TYPE_SET="true"
                shift 2
                ;;
            --s3-bucket)
                S3_BUCKET="$2"
                shift 2
                ;;
            --s3-region)
                S3_REGION="$2"
                shift 2
                ;;
            --primary-ip)
                PRIMARY_IP="$2"
                shift 2
                ;;
            --standby-ip)
                STANDBY_IP="$2"
                shift 2
                ;;
            --data-dir)
                CUSTOM_DATA_DIR="$2"
                PG_DATA_DIR="$2"
                shift 2
                ;;
            --stanza)
                STANZA_NAME="$2"
                shift 2
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Print header
    if [[ "$interactive_mode" == "true" ]]; then
        echo -e "${CYAN}"
        echo "==============================================================================="
        echo "  pgBackRest Standby Backup Setup Script v3.0"
        echo "  PostgreSQL ${PG_VERSION} with S3/EBS Storage Support"
        echo "==============================================================================="
        echo -e "${NC}"
    fi

    # Load existing state
    load_state

    # Show configuration
    if [[ "$interactive_mode" == "true" ]]; then
        log_info "Configuration:"
        log_info "  Primary IP: $PRIMARY_IP"
        log_info "  Standby IP: $STANDBY_IP (this server)"
        log_info "  PostgreSQL Version: $PG_VERSION"
        log_info "  Data Directory: $PG_DATA_DIR"
        log_info "  Stanza Name: $STANZA_NAME"
        log_info "  AWS Region: $AWS_REGION"
        log_info "  Backup Mode: $BACKUP_MODE"
        log_info "  Storage Type: ${STORAGE_TYPE:-to be selected}"
        if [[ -n "$S3_BUCKET" ]]; then
            log_info "  S3 Bucket: $S3_BUCKET"
        fi
        echo

        # Confirmation
        read -p "Do you want to proceed with standby backup setup? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log_info "Setup cancelled"
            exit 0
        fi

        # Prompt for storage type if not already set
        prompt_storage_type

        # Validate S3 access if using S3
        if [[ "$STORAGE_TYPE" == "s3" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
            validate_s3_access || exit 1
        fi
    else
        log_info "=== SCHEDULED STANDBY BACKUP EXECUTION ==="
        log_info "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        log_info "Backup Mode: $BACKUP_MODE"
        log_info "Storage Type: $STORAGE_TYPE"
    fi

    # Execute setup steps
    check_prerequisites

    # Run setup or just backup based on state
    if should_run_setup; then
        # Full setup mode
        if [[ "$STORAGE_TYPE" == "ebs" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
            setup_backup_volume
        fi
        configure_pgbackrest_standby
        create_stanza_and_backup

        # Only create EBS snapshots for ebs or both storage types
        if [[ "$STORAGE_TYPE" == "ebs" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
            create_ebs_snapshot
        fi

        if [[ "$interactive_mode" == "true" ]]; then
            setup_periodic_snapshots
            show_summary
        fi
    else
        # Scheduled backup mode - only run backup and snapshot
        log_info "=== SCHEDULED BACKUP EXECUTION ==="
        create_stanza_and_backup

        # Only create EBS snapshots for ebs or both storage types
        if [[ "$STORAGE_TYPE" == "ebs" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
            create_ebs_snapshot
        fi

        if [[ "$interactive_mode" == "true" ]]; then
            show_summary
        else
            log_success "Scheduled standby backup completed"
            if [[ "$STORAGE_TYPE" == "ebs" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
                log_info "Snapshot: ${SNAPSHOT_ID:-none}"
            fi
            if [[ "$STORAGE_TYPE" == "s3" ]] || [[ "$STORAGE_TYPE" == "both" ]]; then
                log_info "S3 Bucket: $S3_BUCKET"
            fi
        fi
    fi

    log_success "Execution completed successfully!"
}

# Execute main function
main "$@"

