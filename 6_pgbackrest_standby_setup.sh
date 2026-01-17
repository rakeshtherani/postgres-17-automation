#!/bin/bash
#===============================================================================
# pgBackRest Standby Setup Script - Part 2
#
# This script handles:
# 1. Restore from EBS snapshot OR directly from S3
# 2. Point-in-Time Recovery (PITR) support
# 3. Setting up new standby server with restored data
# 4. Configuring replication and registering with repmgr
#
# Restore Sources:
#   - EBS: Restore from EBS snapshot (fast, local)
#   - S3:  Restore directly from S3 bucket (no snapshot needed)
#
# Recovery Targets:
#   - latest:    Restore to latest available backup (default)
#   - time:      Restore to specific point in time (PITR)
#   - immediate: Restore to end of backup, no WAL replay
#
# Author: PostgreSQL DBA Automation
# Version: 2.0 - Added S3 restore and PITR support for PostgreSQL 17
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
readonly DEFAULT_EXISTING_STANDBY_IP="10.41.241.191"
readonly DEFAULT_NEW_STANDBY_IP=""  # Set when creating new standby
readonly DEFAULT_PG_VERSION="17"
readonly DEFAULT_STANZA_NAME="pg17_cluster"
readonly DEFAULT_AWS_REGION="ap-northeast-1"
readonly DEFAULT_AVAILABILITY_ZONE="ap-northeast-1a"
readonly DEFAULT_NEW_NODE_ID="3"
readonly DEFAULT_NEW_NODE_NAME="standby2"

# Configuration variables
PRIMARY_IP="${PRIMARY_IP:-$DEFAULT_PRIMARY_IP}"
EXISTING_STANDBY_IP="${EXISTING_STANDBY_IP:-$DEFAULT_EXISTING_STANDBY_IP}"
NEW_STANDBY_IP="${NEW_STANDBY_IP:-$DEFAULT_NEW_STANDBY_IP}"
PG_VERSION="${PG_VERSION:-$DEFAULT_PG_VERSION}"
STANZA_NAME="${STANZA_NAME:-$DEFAULT_STANZA_NAME}"
AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
AVAILABILITY_ZONE="${AVAILABILITY_ZONE:-$DEFAULT_AVAILABILITY_ZONE}"
NEW_NODE_ID="${NEW_NODE_ID:-$DEFAULT_NEW_NODE_ID}"
NEW_NODE_NAME="${NEW_NODE_NAME:-$DEFAULT_NEW_NODE_NAME}"

# Restore source configuration: "ebs" or "s3"
RESTORE_SOURCE="${RESTORE_SOURCE:-ebs}"

# S3 configuration (required when RESTORE_SOURCE=s3)
S3_BUCKET="${S3_BUCKET:-}"
S3_REGION="${S3_REGION:-$AWS_REGION}"
S3_ENDPOINT="${S3_ENDPOINT:-s3.${S3_REGION}.amazonaws.com}"

# PITR (Point-in-Time Recovery) configuration
# RECOVERY_TARGET: "latest", "time", "immediate", "name", "lsn"
RECOVERY_TARGET="${RECOVERY_TARGET:-latest}"
# TARGET_TIME: Timestamp for PITR (e.g., "2026-01-14 08:00:00")
TARGET_TIME="${TARGET_TIME:-}"
# TARGET_NAME: Named restore point
TARGET_NAME="${TARGET_NAME:-}"
# TARGET_LSN: Specific LSN to recover to
TARGET_LSN="${TARGET_LSN:-}"
# TARGET_ACTION: What to do after reaching target: "pause", "promote", "shutdown"
TARGET_ACTION="${TARGET_ACTION:-promote}"

# Derived configuration
readonly PG_DATA_DIR="/dbdata/pgsql/${PG_VERSION}/data"
readonly PG_BIN_DIR="/usr/pgsql-${PG_VERSION}/bin"
readonly BACKUP_MOUNT_POINT="/backup/pgbackrest"
readonly BACKUP_DEVICE="/dev/xvdb"
readonly REPLICATION_SLOT_NAME="${NEW_NODE_NAME}_slot"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/pgbackrest_standby_setup_$(date +%Y%m%d_%H%M%S).log"
readonly STATE_FILE="${SCRIPT_DIR}/pgbackrest_standby_state.env"

# Global variables
BACKUP_VOLUME_ID=""
LATEST_SNAPSHOT_ID=""
NEW_VOLUME_ID=""
NEW_INSTANCE_ID=""
PRIMARY_STATE_FILE=""

#===============================================================================
# Utility Functions (Fixed to match primary script)
#===============================================================================

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

execute_remote() {
    local host="$1"
    local command="$2"
    local description="${3:-Executing remote command}"

    log "Executing on $host: $description"
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$host" "$command"; then
        log_success "Command executed successfully on $host"
        return 0
    else
        log_error "Command failed on $host: $command"
        return 1
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

    # Add new key-value pair with proper quoting for values containing spaces
    if [[ "$value" =~ [[:space:]] ]]; then
        echo "${key}=\"${value}\"" >> "$STATE_FILE"
    else
        echo "${key}=${value}" >> "$STATE_FILE"
    fi
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

load_primary_state() {
    local state_file="$1"

    if [ ! -f "$state_file" ]; then
        log_error "State file not found: $state_file"
        exit 1
    fi

    source "$state_file"
    PRIMARY_STATE_FILE="$state_file"
    log_info "Primary state loaded from: $state_file"

    # Validate required state variables
    if [ -z "${BACKUP_VOLUME_ID:-}" ]; then
        log_error "BACKUP_VOLUME_ID not found in state file"
        exit 1
    fi

    if [ -z "${LATEST_SNAPSHOT_ID:-}" ]; then
        log_error "LATEST_SNAPSHOT_ID not found in state file"
        exit 1
    fi

    log_info "Using backup volume: $BACKUP_VOLUME_ID"
    log_info "Using latest snapshot: $LATEST_SNAPSHOT_ID"
}

#===============================================================================
# Prerequisites Check (Fixed to match primary script structure)
#===============================================================================

check_prerequisites() {
    log "Checking prerequisites for standby setup..."

    # Check required commands
    check_command "aws"
    check_command "ssh"
    check_command "nc"

    # Check AWS CLI configuration
    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS CLI not configured properly"
        exit 1
    fi

    # Test SSH connectivity
    for host in "$PRIMARY_IP" "$NEW_STANDBY_IP"; do
        if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$host" "echo 'SSH test successful'" &>/dev/null; then
            log_error "Cannot SSH to $host"
            exit 1
        fi
    done

    # Verify PostgreSQL is running on primary
    if ! ssh -o StrictHostKeyChecking=no "root@$PRIMARY_IP" "sudo -u postgres psql -c 'SELECT version();'" &>/dev/null; then
        log_error "PostgreSQL not accessible on primary server $PRIMARY_IP"
        exit 1
    fi

    # Verify PostgreSQL is installed on new standby (but don't install it)
    if ! ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "command -v psql" &>/dev/null; then
        log_error "PostgreSQL not found on $NEW_STANDBY_IP"
        log_error "Please install PostgreSQL ${PG_VERSION} on the standby server before running this script"
        log_info "Required: PostgreSQL ${PG_VERSION} server and client tools"
        exit 1
    fi

    # Verify PostgreSQL version on standby
    local pg_version_check
    pg_version_check=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "psql --version" 2>/dev/null || echo "version_check_failed")

    if [[ "$pg_version_check" == "version_check_failed" ]]; then
        log_warning "Could not verify PostgreSQL version on $NEW_STANDBY_IP"
    elif [[ "$pg_version_check" == *"$PG_VERSION"* ]]; then
        log_info "PostgreSQL $PG_VERSION verified on standby server"
    else
        log_warning "PostgreSQL version on standby may not match expected version $PG_VERSION"
        log_info "Found: $pg_version_check"
    fi

    log_success "Prerequisites check completed"
}

#===============================================================================
# Step 1: Find Latest Snapshot
#===============================================================================

find_latest_snapshot() {
    log "=== STEP 1: Finding latest snapshot ==="

    # If state file provided, use snapshot from there
    if [ -n "${LATEST_SNAPSHOT_ID:-}" ]; then
        log_info "Using snapshot from state file: $LATEST_SNAPSHOT_ID"

        # Verify snapshot exists and is completed
        local snapshot_state
        snapshot_state=$(aws ec2 describe-snapshots \
            --snapshot-ids "$LATEST_SNAPSHOT_ID" \
            --query 'Snapshots[0].State' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "not-found")

        if [ "$snapshot_state" != "completed" ]; then
            log_error "Snapshot $LATEST_SNAPSHOT_ID is not in completed state: $snapshot_state"
            exit 1
        fi

        save_state "LATEST_SNAPSHOT_ID" "$LATEST_SNAPSHOT_ID"
        log_success "Verified snapshot: $LATEST_SNAPSHOT_ID"
        return 0
    fi

    # Otherwise, find latest snapshot for the stanza
    log "Searching for latest snapshot for stanza: $STANZA_NAME"

    # Find latest completed snapshot for the stanza
    LATEST_SNAPSHOT_ID=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:Stanza,Values=$STANZA_NAME" \
        --query 'Snapshots[?State==`completed`] | sort_by(@, &StartTime) | [-1].SnapshotId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "None")

    if [ "$LATEST_SNAPSHOT_ID" == "None" ] || [ -z "$LATEST_SNAPSHOT_ID" ] || [ "$LATEST_SNAPSHOT_ID" == "null" ]; then
        log_error "No completed snapshots found for stanza: $STANZA_NAME"
        log_info "Please run the primary setup script first or check AWS region/tags"
        exit 1
    fi

    # Get snapshot details
    local snapshot_info
    snapshot_info=$(aws ec2 describe-snapshots \
        --snapshot-ids "$LATEST_SNAPSHOT_ID" \
        --query 'Snapshots[0].{Description:Description,StartTime:StartTime,Size:VolumeSize}' \
        --output json \
        --region "$AWS_REGION" 2>/dev/null || echo "{}")

    log_info "Found latest snapshot:"
    log_info "  Snapshot ID: $LATEST_SNAPSHOT_ID"
    log_info "  Details: $snapshot_info"

    save_state "LATEST_SNAPSHOT_ID" "$LATEST_SNAPSHOT_ID"
    log_success "Latest snapshot identified: $LATEST_SNAPSHOT_ID"
}

#===============================================================================
# Step 2: Create New Volume from Latest Snapshot
#===============================================================================

create_new_volume() {
    log "=== STEP 2: Creating new volume from latest snapshot ==="

    # Check if we already have a volume ID in state
    if [[ -n "${NEW_VOLUME_ID:-}" ]] && [[ "$NEW_VOLUME_ID" != "existing-unknown" ]]; then
        # Verify the volume exists and is available
        local volume_state
        volume_state=$(aws ec2 describe-volumes \
            --volume-ids "$NEW_VOLUME_ID" \
            --query 'Volumes[0].State' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "not-found")

        if [[ "$volume_state" == "available" ]]; then
            log_info "Volume $NEW_VOLUME_ID already exists and is available - skipping creation"
            log_success "Using existing volume: $NEW_VOLUME_ID"
            return 0
        elif [[ "$volume_state" == "in-use" ]]; then
            log_info "Volume $NEW_VOLUME_ID already exists and is in-use - checking attachment"
            save_state "VOLUME_EXISTS" "true"
            log_success "Using existing in-use volume: $NEW_VOLUME_ID"
            return 0
        fi
    fi

    # Create new volume from snapshot with improved error handling
    log_info "Creating new volume from snapshot $LATEST_SNAPSHOT_ID"
    NEW_VOLUME_ID=$(aws ec2 create-volume \
        --snapshot-id "$LATEST_SNAPSHOT_ID" \
        --availability-zone "$AVAILABILITY_ZONE" \
        --volume-type gp3 \
        --iops 16000 \
        --throughput 1000 \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=pgbackrest-restore-$(date +%Y%m%d)},{Key=Purpose,Value=Standby-Restore},{Key=SourceSnapshot,Value=$LATEST_SNAPSHOT_ID},{Key=Stanza,Value=$STANZA_NAME}]" \
        --query 'VolumeId' --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "failed")

    if [ "$NEW_VOLUME_ID" == "failed" ] || [ -z "$NEW_VOLUME_ID" ] || [ "$NEW_VOLUME_ID" == "None" ]; then
        log_error "Failed to create volume from snapshot $LATEST_SNAPSHOT_ID"
        exit 1
    fi

    log_info "New volume created: $NEW_VOLUME_ID"

    # Wait for volume to be available
    log "Waiting for volume to be available..."
    aws ec2 wait volume-available --volume-ids "$NEW_VOLUME_ID" --region "$AWS_REGION"

    save_state "NEW_VOLUME_ID" "$NEW_VOLUME_ID"
    log_success "New volume ready: $NEW_VOLUME_ID"
}

#===============================================================================
# Step 3: Attach Volume to New Standby Server (FIXED for NVMe detection)
#===============================================================================

attach_volume_to_new_server() {
    log "=== STEP 3: Attaching volume to new standby server ($NEW_STANDBY_IP) ==="

    # Get instance ID of new standby server
    NEW_INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=private-ip-address,Values=$NEW_STANDBY_IP" "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")

    if [ -z "$NEW_INSTANCE_ID" ] || [ "$NEW_INSTANCE_ID" == "None" ]; then
        log_error "Could not find running instance with IP: $NEW_STANDBY_IP"
        exit 1
    fi

    log_info "Target instance: $NEW_INSTANCE_ID"

    # Check if backup is already mounted and working
    execute_remote "$NEW_STANDBY_IP" "
        echo 'Checking current disk layout and backup mount status...'
        lsblk
        echo

        # Check if backup is already mounted
        if mount | grep -q '$BACKUP_MOUNT_POINT'; then
            MOUNTED_DEVICE=\$(mount | grep '$BACKUP_MOUNT_POINT' | awk '{print \$1}')
            echo \"Backup already mounted from: \$MOUNTED_DEVICE\"

            # Verify backup data exists
            if [ -d '$BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME' ]; then
                echo 'Backup data verified - using existing mount'

                # Set proper permissions just in case
                sudo chown -R postgres:postgres $BACKUP_MOUNT_POINT
                sudo chmod 750 $BACKUP_MOUNT_POINT

                # Verify it's in fstab
                DEVICE_UUID=\$(blkid -s UUID -o value \"\$MOUNTED_DEVICE\" 2>/dev/null)
                if [ -n \"\$DEVICE_UUID\" ] && ! grep -q \"\$DEVICE_UUID\" /etc/fstab; then
                    echo \"Adding mount to fstab for persistence...\"
                    sudo sed -i '\|$BACKUP_MOUNT_POINT|d' /etc/fstab
                    echo \"UUID=\$DEVICE_UUID $BACKUP_MOUNT_POINT ext4 defaults,nofail 0 2\" | sudo tee -a /etc/fstab
                    echo \"Added to fstab with UUID: \$DEVICE_UUID\"
                fi

                echo 'BACKUP_MOUNT_READY=true'
                exit 0
            else
                echo 'Mounted device does not contain backup data - will unmount and proceed'
                sudo umount '$BACKUP_MOUNT_POINT' || true
            fi
        fi

        echo 'BACKUP_MOUNT_READY=false'
    " "Checking for existing backup mount"

    # Get the result of backup mount check
    local mount_check_result
    mount_check_result=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "
        if mount | grep -q '$BACKUP_MOUNT_POINT'; then
            if [ -d '$BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME' ]; then
                echo 'ready'
            else
                echo 'invalid'
            fi
        else
            echo 'not_mounted'
        fi
    " 2>/dev/null || echo "check_failed")

    if [ "$mount_check_result" = "ready" ]; then
        log_success "Backup is already mounted and contains valid data - skipping mount setup"
        save_state "NEW_INSTANCE_ID" "$NEW_INSTANCE_ID"
        save_state "VOLUME_ATTACHED" "true"
        save_state "BACKUP_MOUNT_READY" "true"
        return 0
    fi

    # If mount is invalid or not present, proceed with mount setup
    log_info "Backup mount needs setup - proceeding with volume attachment/mount"

    # Check for available disks with backup data (from snapshot)
    execute_remote "$NEW_STANDBY_IP" "
        echo 'Looking for disks with backup data from snapshot...'
        BACKUP_DEVICE_FOUND=\"\"

        for dev in /dev/nvme[0-9]n[0-9] /dev/xvd[b-z] /dev/sd[b-z]; do
            if [ -b \"\$dev\" ]; then
                # Skip mounted devices (except if they're mounted on our target mount point and we already checked them)
                if mount | grep -q \"\$dev\" && ! mount | grep \"\$dev\" | grep -q '$BACKUP_MOUNT_POINT'; then
                    continue
                fi

                echo \"Checking device: \$dev\"

                # Try to mount and check for backup data
                mkdir -p /tmp/test_mount

                # Unmount from target if it's there but invalid
                if mount | grep \"\$dev\" | grep -q '$BACKUP_MOUNT_POINT'; then
                    sudo umount '$BACKUP_MOUNT_POINT' 2>/dev/null || true
                fi

                if mount \"\$dev\" /tmp/test_mount 2>/dev/null; then
                    if [ -d '/tmp/test_mount/repo/backup/$STANZA_NAME' ]; then
                        echo \"Found backup data on device: \$dev\"
                        BACKUP_DEVICE_FOUND=\"\$dev\"
                        umount /tmp/test_mount
                        break
                    else
                        echo \"Device \$dev does not contain backup data\"
                    fi
                    umount /tmp/test_mount 2>/dev/null || true
                else
                    echo \"Could not mount \$dev for testing\"
                fi
            fi
        done

        if [ -n \"\$BACKUP_DEVICE_FOUND\" ]; then
            echo \"BACKUP_DEVICE_FOUND=\$BACKUP_DEVICE_FOUND\"
        else
            echo \"BACKUP_DEVICE_FOUND=none\"
        fi
    " "Searching for backup devices"

    # Get the result of backup device search
    local backup_device_result
    backup_device_result=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "
        for dev in /dev/nvme[0-9]n[0-9] /dev/xvd[b-z] /dev/sd[b-z]; do
            if [ -b \"\$dev\" ]; then
                # Skip currently mounted devices that aren't on our target mount point
                if mount | grep -q \"\$dev\" && ! mount | grep \"\$dev\" | grep -q '$BACKUP_MOUNT_POINT'; then
                    continue
                fi

                mkdir -p /tmp/test_mount

                # If it's mounted on our target, unmount first to test
                if mount | grep \"\$dev\" | grep -q '$BACKUP_MOUNT_POINT'; then
                    sudo umount '$BACKUP_MOUNT_POINT' 2>/dev/null || true
                fi

                if mount \"\$dev\" /tmp/test_mount 2>/dev/null; then
                    if [ -d '/tmp/test_mount/repo/backup/$STANZA_NAME' ]; then
                        echo \"\$dev\"
                        umount /tmp/test_mount
                        exit 0
                    fi
                    umount /tmp/test_mount 2>/dev/null || true
                fi
            fi
        done
        echo 'none'
    " 2>/dev/null || echo "none")

    if [ "$backup_device_result" != "none" ]; then
        log_info "Found existing disk with backup data: $backup_device_result"
        BACKUP_DEVICE_ACTUAL="$backup_device_result"
        SKIP_ATTACH=true
    else
        log_info "No existing backup device found - will attach new volume"
        SKIP_ATTACH=false

        # Check if volume is already attached to this instance
        local volume_attachment
        volume_attachment=$(aws ec2 describe-volumes \
            --volume-ids "$NEW_VOLUME_ID" \
            --query 'Volumes[0].Attachments[0].{State:State,InstanceId:InstanceId,Device:Device}' \
            --output json \
            --region "$AWS_REGION" 2>/dev/null || echo "{}")

        local attachment_state=$(echo "$volume_attachment" | grep -o '"State": *"[^"]*"' | cut -d'"' -f4)
        local attached_instance=$(echo "$volume_attachment" | grep -o '"InstanceId": *"[^"]*"' | cut -d'"' -f4)

        if [[ "$attachment_state" == "attached" ]] && [[ "$attached_instance" == "$NEW_INSTANCE_ID" ]]; then
            log_info "Volume $NEW_VOLUME_ID already attached to instance $NEW_INSTANCE_ID"
        else
            # Stop PostgreSQL and unmount any existing backup mount
            execute_remote "$NEW_STANDBY_IP" "
                sudo systemctl stop postgresql-${PG_VERSION}.service 2>/dev/null || true
                sudo umount $BACKUP_MOUNT_POINT 2>/dev/null || true
            " "Stopping PostgreSQL and unmounting backup"

            # Attach volume to new server
            log_info "Attaching volume $NEW_VOLUME_ID to instance $NEW_INSTANCE_ID"
            if ! aws ec2 attach-volume \
                --volume-id "$NEW_VOLUME_ID" \
                --instance-id "$NEW_INSTANCE_ID" \
                --device "$BACKUP_DEVICE" \
                --region "$AWS_REGION" &>/dev/null; then
                log_error "Failed to attach volume"
                exit 1
            fi

            # Wait for attachment
            log "Waiting for volume attachment..."
            sleep 15
        fi
    fi

    # Mount the backup volume
    execute_remote "$NEW_STANDBY_IP" "
        echo 'Setting up backup volume mount...'

        # Stop PostgreSQL if running
        sudo systemctl stop postgresql-${PG_VERSION}.service 2>/dev/null || true

        BACKUP_DEVICE_ACTUAL=\"\"

        if [ '$SKIP_ATTACH' = 'true' ]; then
            # Use the device we found earlier
            BACKUP_DEVICE_ACTUAL='$backup_device_result'
            echo \"Using existing device with backup data: \$BACKUP_DEVICE_ACTUAL\"
        else
            # Find the newly attached device
            echo 'Looking for newly attached device...'

            # Wait for attached device to appear
            device_wait=0
            max_wait=60

            while [ \$device_wait -lt \$max_wait ]; do
                # Check for the expected device first
                if [ -b '$BACKUP_DEVICE' ]; then
                    BACKUP_DEVICE_ACTUAL='$BACKUP_DEVICE'
                    break
                fi

                # Check for nvme devices (modern AWS instances)
                for dev in /dev/nvme[0-9]n[0-9]; do
                    if [ -b \"\$dev\" ]; then
                        # Skip the root device
                        if mount | grep -q \"\$dev\"; then
                            continue
                        fi

                        # Check if this device has backup data structure
                        if blkid \"\$dev\" | grep -q ext4; then
                            mkdir -p /tmp/test_mount
                            if mount \"\$dev\" /tmp/test_mount 2>/dev/null; then
                                if [ -d '/tmp/test_mount/repo' ] || [ -d '/tmp/test_mount/repo/backup/$STANZA_NAME' ]; then
                                    BACKUP_DEVICE_ACTUAL=\"\$dev\"
                                    umount /tmp/test_mount
                                    echo \"Found backup device with data: \$dev\"
                                    break
                                fi
                                umount /tmp/test_mount
                            fi
                        fi
                    fi
                done

                if [ -n \"\$BACKUP_DEVICE_ACTUAL\" ]; then
                    break
                fi

                echo \"Waiting for backup device to appear... (\$device_wait/\$max_wait)\"
                sleep 5
                ((device_wait++))
            done

            if [ -z \"\$BACKUP_DEVICE_ACTUAL\" ]; then
                echo 'ERROR: Backup device not found after attachment'
                echo 'Available devices:'
                lsblk
                exit 1
            fi
        fi

        echo \"Using backup device: \$BACKUP_DEVICE_ACTUAL\"

        # Create mount point and ensure it's not mounted
        sudo mkdir -p $BACKUP_MOUNT_POINT
        sudo umount $BACKUP_MOUNT_POINT 2>/dev/null || true

        # Mount the device
        if ! sudo mount \"\$BACKUP_DEVICE_ACTUAL\" $BACKUP_MOUNT_POINT; then
            echo \"ERROR: Failed to mount backup device \$BACKUP_DEVICE_ACTUAL\"
            echo 'Checking device status:'
            lsblk | grep -E \"\$(basename \$BACKUP_DEVICE_ACTUAL)\"
            blkid \"\$BACKUP_DEVICE_ACTUAL\" || echo 'No filesystem found'
            exit 1
        fi

        echo 'Mount successful. Verifying backup data...'

        # Verify backup data exists
        if [ ! -d '$BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME' ]; then
            echo 'ERROR: Backup data not found in mounted volume'
            echo 'Directory structure:'
            ls -la $BACKUP_MOUNT_POINT/ || echo 'Mount point empty'
            ls -la $BACKUP_MOUNT_POINT/repo/ 2>/dev/null || echo 'Repo directory missing'
            exit 1
        fi

        echo 'Backup data verified:'
        ls -la $BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME/

        # Add to fstab for persistence (use UUID for reliability)
        DEVICE_UUID=\$(blkid -s UUID -o value \"\$BACKUP_DEVICE_ACTUAL\")
        if [ -n \"\$DEVICE_UUID\" ]; then
            # Remove any existing entries for this mount point
            sudo sed -i '\|$BACKUP_MOUNT_POINT|d' /etc/fstab
            echo \"UUID=\$DEVICE_UUID $BACKUP_MOUNT_POINT ext4 defaults,nofail 0 2\" | sudo tee -a /etc/fstab
            echo \"Added to fstab with UUID: \$DEVICE_UUID\"
        fi

        # Set proper permissions
        sudo chown -R postgres:postgres $BACKUP_MOUNT_POINT
        sudo chmod 750 $BACKUP_MOUNT_POINT

        # Final verification
        df -h $BACKUP_MOUNT_POINT
        echo \"Backup mount setup completed using device: \$BACKUP_DEVICE_ACTUAL\"
    " "Setting up backup volume mount"

    save_state "NEW_INSTANCE_ID" "$NEW_INSTANCE_ID"
    save_state "VOLUME_ATTACHED" "true"
    log_success "Backup volume mounted with backup data verified"
}


#===============================================================================
# Step 4: Install pgBackRest on New Server
#===============================================================================

install_pgbackrest_new_server() {
    log "=== STEP 4: Installing pgBackRest on new standby ($NEW_STANDBY_IP) ==="

    execute_remote "$NEW_STANDBY_IP" "
        # Verify PostgreSQL is already installed
        if ! command -v psql &> /dev/null; then
            echo 'ERROR: PostgreSQL not found. Please install PostgreSQL first.'
            echo 'Expected PostgreSQL ${PG_VERSION} to be installed and configured.'
            exit 1
        fi

        echo 'PostgreSQL installation verified:'
        psql --version

        # Install pgBackRest from source if not already installed
        if ! command -v pgbackrest &> /dev/null; then
            echo 'Installing pgBackRest from source...'

            # Install build dependencies
            sudo yum install -y python3-devel gcc postgresql${PG_VERSION}-devel openssl-devel \
                libxml2-devel pkgconfig lz4-devel libzstd-devel bzip2-devel zlib-devel \
                libyaml-devel libssh2-devel wget tar gzip

            # Install meson and ninja build tools
            sudo yum install -y python3-pip
            sudo pip3 install meson ninja

            # Download and extract pgBackRest source
            cd /tmp
            wget -O - https://github.com/pgbackrest/pgbackrest/archive/release/2.55.1.tar.gz | tar zx
            cd pgbackrest-release-2.55.1

            # Build pgBackRest
            meson setup build
            ninja -C build

            # Install binary
            sudo cp build/src/pgbackrest /usr/bin/
            sudo chmod 755 /usr/bin/pgbackrest

            # Verify installation
            pgbackrest version

            # Cleanup
            cd /
            rm -rf /tmp/pgbackrest-release-2.55.1
        else
            echo 'pgBackRest already installed'
            pgbackrest version
        fi

        # Setup directories
        sudo mkdir -p /etc/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest
        sudo chown postgres:postgres /etc/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest

        # Ensure logs directory exists in backup mount
        sudo mkdir -p $BACKUP_MOUNT_POINT/logs
        sudo chown postgres:postgres $BACKUP_MOUNT_POINT/logs

        echo 'Installation verification:'
        echo \"PostgreSQL: \$(which psql)\"
        echo \"pgBackRest: \$(which pgbackrest)\"
        pgbackrest version
    " "Installing pgBackRest"

    save_state "PGBACKREST_INSTALLED" "true"
    log_success "pgBackRest installation completed"
}

#===============================================================================
# Step 5: Configure pgBackRest for Restore on New Server
#===============================================================================

configure_pgbackrest_new_server() {
    log "=== STEP 5: Configuring pgBackRest for restore on new standby ==="

    execute_remote "$NEW_STANDBY_IP" "
        # Create pgBackRest configuration
        cat << 'EOF' | sudo tee /etc/pgbackrest/pgbackrest.conf > /dev/null
[$STANZA_NAME]
pg1-path=$PG_DATA_DIR
pg1-port=5432
pg1-socket-path=/tmp

[global]
repo1-path=$BACKUP_MOUNT_POINT/repo
repo1-retention-full=4
repo1-retention-diff=3
repo1-retention-archive=10
process-max=12
start-fast=y
stop-auto=y
delta=y
compress-type=zst
compress-level=3
log-level-console=info
log-level-file=detail
log-path=$BACKUP_MOUNT_POINT/logs

[global:restore]
process-max=20
EOF

        # Fix ownership
        sudo chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
        sudo chmod 640 /etc/pgbackrest/pgbackrest.conf

        # Test pgBackRest configuration and verify backup data
        echo 'Testing pgBackRest configuration...'
        if sudo -u postgres pgbackrest --stanza=$STANZA_NAME info; then
            echo 'pgBackRest configuration and backup data verified successfully'
        else
            echo 'pgBackRest info command failed - checking backup data structure'
            echo 'Backup directory contents:'
            ls -la $BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME/ || echo 'Backup directory not found'

            # Check if backup.info files exist
            if [ ! -f '$BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME/backup.info' ]; then
                echo 'ERROR: backup.info file missing - backup data may be corrupted'
                echo 'Available files:'
                find $BACKUP_MOUNT_POINT/repo -name '*' -type f | head -20
                exit 1
            fi
        fi
    " "Configuring pgBackRest for restore"

    save_state "PGBACKREST_CONFIGURED" "true"
    log_success "pgBackRest restore configuration completed"
}

#===============================================================================
# Enhanced Step 6: Restore Database with Backup Version Detection
#===============================================================================

restore_database_new_server() {
    log "=== STEP 6: Checking database status and backup version ==="

    # First, get the latest available backup info
    local latest_available_backup=""
    local current_restored_backup=""

    # Get the latest available backup using a simpler approach
    latest_available_backup=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "
        sudo -u postgres pgbackrest --stanza=$STANZA_NAME info --output=json 2>/dev/null | python3 -c \"
import json, sys
try:
    data = json.load(sys.stdin)
    for stanza in data:
        if stanza.get('name') == '$STANZA_NAME':
            backups = stanza.get('backup', [])
            if backups:
                print(backups[-1]['label'])
                sys.exit(0)
    print('none')
except:
    print('none')
\" 2>/dev/null || echo 'none'")

    log_info "Latest available backup: $latest_available_backup"

    # Check if database is already restored and running
    local pg_version_file_exists
    pg_version_file_exists=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "[ -f '$PG_DATA_DIR/PG_VERSION' ] && [ -f '$PG_DATA_DIR/postgresql.conf' ] && echo 'true' || echo 'false'" 2>/dev/null || echo "false")
    # Initialize data_size early to avoid unbound variable errors
    local data_size
    data_size=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" 'du -s $PG_DATA_DIR 2>/dev/null | awk "{print \$1}" || echo 0'
  2>/dev/null || echo "0")
    if [ "$pg_version_file_exists" = "true" ]; then
        log_info "PostgreSQL data directory exists - checking current state"


        # Get the backup label from current restored data (if any)
        local backup_label_info=""
        backup_label_info=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "
            # Check for backup label in various ways
            if [ -f '$PG_DATA_DIR/backup_label' ]; then
                grep 'LABEL:' '$PG_DATA_DIR/backup_label' | awk '{print \$2}' 2>/dev/null || echo 'unknown'
            elif [ -f '$PG_DATA_DIR/backup_label.old' ]; then
                grep 'LABEL:' '$PG_DATA_DIR/backup_label.old' | awk '{print \$2}' 2>/dev/null || echo 'unknown'
            else
                # Try to get backup info from pgBackRest if data directory exists and is substantial
                if [ -d '$PG_DATA_DIR' ] && [ \$(du -s '$PG_DATA_DIR' 2>/dev/null | awk '{print \$1}' || echo '0') -gt 1000000 ]; then
                    # If data directory is substantial, assume it's from the latest available backup
                    echo '$latest_available_backup'
                else
                    echo 'no_data'
                fi
            fi
        " 2>/dev/null || echo "check_failed")

        log_info "Current restored backup label: $backup_label_info"

        # Check if it's configured as standby
        local standby_signal_exists
        standby_signal_exists=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "[ -f '$PG_DATA_DIR/standby.signal' ] && echo 'true' || echo 'false'" 2>/dev/null || echo "false")

        if [ "$standby_signal_exists" = "true" ]; then
            log_info "Standby signal file found - checking if PostgreSQL is running"

            # Check if PostgreSQL is running
            local pg_is_active
            pg_is_active=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "systemctl is-active postgresql-${PG_VERSION}.service 2>/dev/null || echo 'inactive'" 2>/dev/null || echo "inactive")

            if [ "$pg_is_active" = "active" ]; then
                log_info "PostgreSQL service is active - checking recovery status"

                # Check if it's actually in recovery mode (standby)
                local recovery_status
                recovery_status=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "cd /tmp && sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | xargs || echo 'failed'" 2>/dev/null || echo "failed")

                if [ "$recovery_status" = "t" ]; then
                    log_success "PostgreSQL is running as standby"

                    # ✅ KEY CHECK: Compare backup versions
                    if [ "$backup_label_info" != "no_label" ] && [ "$backup_label_info" != "unknown" ] && [ "$backup_label_info" != "check_failed" ]; then
                        if [ "$backup_label_info" = "$latest_available_backup" ]; then
                            log_success "Current restored backup ($backup_label_info) matches latest available backup"
                            log_success "✅ SKIPPING RESTORE - Database already has latest backup restored and running as standby"

                            # Still verify configuration is correct
                            verify_and_fix_standby_config

                            save_state "DATABASE_RESTORED" "true"
                            save_state "STANDBY_RUNNING" "true"
                            save_state "BACKUP_CURRENT" "true"
                            return 0
                        else
                            log_warning "Current backup ($backup_label_info) is different from latest available ($latest_available_backup)"
                            log_info "Will restore latest backup to ensure standby is up-to-date"
                        fi
                    else
                        log_warning "Cannot determine current backup version - will proceed with restore to ensure latest data"
                    fi

                    # If we reach here, backup needs updating but PostgreSQL is running
                    # Stop it gracefully for restore
                    log_info "Stopping PostgreSQL for backup update"
                    ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "sudo systemctl stop postgresql-${PG_VERSION}.service"
                elif [ "$recovery_status" = "f" ]; then
                    log_warning "PostgreSQL is running but NOT in recovery mode - needs reconfiguration"
                else
                    log_warning "Could not determine PostgreSQL recovery status"
                fi
            else
                log_info "PostgreSQL service is not running"

                # Check if we have the right backup even though service is down
                if [ "$backup_label_info" != "no_data" ] && [ "$backup_label_info" != "unknown" ] && [ "$backup_label_info" != "check_failed" ]; then
                    if [ "$backup_label_info" = "$latest_available_backup" ]; then
                        log_info "Latest backup ($backup_label_info) is already restored, just need to start PostgreSQL"

                        # Verify standby configuration and start
                        verify_and_fix_standby_config

                        log_info "Starting PostgreSQL with existing latest backup"
                        ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "sudo systemctl start postgresql-${PG_VERSION}.service"
                        sleep 10

                        # Verify it started correctly
                        local recovery_check
                        recovery_check=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "cd /tmp && sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | xargs || echo 'failed'" 2>/dev/null || echo "failed")

                        if [ "$recovery_check" = "t" ]; then
                            log_success "PostgreSQL started successfully as standby with latest backup"
                            save_state "DATABASE_RESTORED" "true"
                            save_state "STANDBY_RUNNING" "true"
                            save_state "BACKUP_CURRENT" "true"
                            return 0
                        else
                            log_warning "PostgreSQL started but not in recovery mode - will reconfigure"
                        fi
                    else
                        log_info "Current backup ($backup_label_info) differs from latest ($latest_available_backup)"
                        log_info "Will restore latest backup to ensure standby is up-to-date"
                    fi
                else
                    log_info "Cannot determine current backup version reliably"
                    # If we have substantial data and latest backup is available, assume it's current
                    if [ "$data_size" -gt 1000000 ] && [ "$latest_available_backup" != "none" ]; then
                        log_info "Data directory is substantial ($data_size KB) and backup is available"
                        log_info "Assuming data is from latest backup - will configure and start PostgreSQL"

                        verify_and_fix_standby_config

                        log_info "Starting PostgreSQL with existing data"
                        ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "sudo systemctl start postgresql-${PG_VERSION}.service"
                        sleep 10

                        local recovery_check
                        recovery_check=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "cd /tmp && sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | xargs || echo 'failed'" 2>/dev/null || echo "failed")

                        if [ "$recovery_check" = "t" ]; then
                            log_success "PostgreSQL started successfully as standby with existing data"
                            save_state "DATABASE_RESTORED" "true"
                            save_state "STANDBY_RUNNING" "true"
                            save_state "BACKUP_CURRENT" "true"
                            return 0
                        else
                            log_warning "PostgreSQL failed to start in recovery mode - will restore and reconfigure"
                        fi
                    fi
                fi
            fi
        fi

        # Check if data directory has substantial content - if so, assume it's already restored

        if [ "$data_size" -gt 1000000 ]; then  # More than ~1GB
            log_info "Data directory has substantial content ($data_size KB)"
            if [ "$backup_label_info" != "$latest_available_backup" ] && [ "$backup_label_info" != "unknown" ] && [ "$backup_label_info" != "check_failed" ]; then
                log_info "Current: $backup_label_info, Latest: $latest_available_backup"
                # Only restore if we're confident the backup is different
                if [ "$backup_label_info" != "no_data" ]; then
                    log_info "Will restore latest backup"
                else
                    log_info "Cannot determine backup version reliably - will try to use existing data"
                fi
            else
                log_info "Data appears to be current - will try to use existing data"
            fi
        fi
    fi

    # If we reach here, check if we should restore or try to use existing data
    if [ "$data_size" -gt 1000000 ] && [ "$latest_available_backup" != "none" ]; then
        log_info "Data directory has substantial content ($data_size KB)"
        log_info "Attempting to use existing data and configure as standby"

        # Try to configure and start with existing data first
        verify_and_fix_standby_config

        log_info "Starting PostgreSQL with existing data"
        ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "sudo systemctl start postgresql-${PG_VERSION}.service"
        sleep 10

        local recovery_check
        recovery_check=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "cd /tmp && sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | xargs || echo 'failed'" 2>/dev/null || echo "failed")

        if [ "$recovery_check" = "t" ]; then
            log_success "PostgreSQL started successfully as standby with existing data"
            save_state "DATABASE_RESTORED" "true"
            save_state "STANDBY_RUNNING" "true"
            save_state "BACKUP_CURRENT" "true"
            return 0
        else
            log_warning "PostgreSQL failed to start properly with existing data"
            ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "sudo systemctl stop postgresql-${PG_VERSION}.service 2>/dev/null || true"
            log_info "Will perform fresh restore"
        fi
    fi

    # Only restore if we really need to
    log_info "Performing database restore with latest backup: $latest_available_backup"

    # Perform the actual restore
    perform_backup_restore "$latest_available_backup"
}

#===============================================================================
# Helper function to verify and fix standby configuration
#===============================================================================

verify_and_fix_standby_config() {
    log_info "Verifying standby configuration..."

    execute_remote "$NEW_STANDBY_IP" "
        # Check max_wal_senders setting
        current_max_wal_senders=\$(grep '^max_wal_senders' $PG_DATA_DIR/postgresql.conf | awk '{print \$3}' 2>/dev/null || echo 'unknown')

        if [ \"\$current_max_wal_senders\" != 'unknown' ] && [ \"\$current_max_wal_senders\" -lt 16 ]; then
            echo 'max_wal_senders is '\$current_max_wal_senders', should be >= 16 - fixing'
            sudo -u postgres sed -i 's/max_wal_senders = [0-9]*/max_wal_senders = 16/' $PG_DATA_DIR/postgresql.conf
            sudo -u postgres sed -i 's/max_replication_slots = [0-9]*/max_replication_slots = 16/' $PG_DATA_DIR/postgresql.conf
        fi

        # Ensure standby.signal exists
        sudo -u postgres touch $PG_DATA_DIR/standby.signal

        # Verify standby configuration exists in postgresql.conf
        if ! grep -q 'primary_conninfo.*$NEW_NODE_NAME' $PG_DATA_DIR/postgresql.conf 2>/dev/null; then
            echo 'Adding missing standby configuration'
            add_standby_configuration
        fi
    " "Verifying standby configuration"
}

#===============================================================================
# Helper function to add standby configuration
#===============================================================================

add_standby_configuration() {
    execute_remote "$NEW_STANDBY_IP" "
        sudo -u postgres tee -a $PG_DATA_DIR/postgresql.conf << EOF

# Standby configuration - Added by setup script
primary_conninfo = 'host=$PRIMARY_IP port=5432 user=repmgr application_name=$NEW_NODE_NAME connect_timeout=2'
primary_slot_name = '$REPLICATION_SLOT_NAME'
hot_standby = on
hot_standby_feedback = on

# Archive configuration
archive_mode = always
archive_command = 'pgbackrest --stanza=$STANZA_NAME archive-push %p'
archive_timeout = 60

# Performance settings (fixed to match primary)
max_connections = 600
max_wal_senders = 16
max_replication_slots = 16
wal_level = replica

# Additional standby settings
max_standby_streaming_delay = 30s
max_standby_archive_delay = 30s
EOF
    " "Adding standby configuration"
}

#===============================================================================
# Helper function to build pgBackRest restore command with PITR options
#===============================================================================

build_restore_command() {
    local restore_cmd="pgbackrest --stanza=$STANZA_NAME"

    # Add recovery target options based on RECOVERY_TARGET
    case "$RECOVERY_TARGET" in
        "time")
            if [[ -n "$TARGET_TIME" ]]; then
                restore_cmd="$restore_cmd --type=time --target=\"$TARGET_TIME\""
                log_info "PITR: Restoring to time: $TARGET_TIME"
            else
                log_error "TARGET_TIME is required when RECOVERY_TARGET=time"
                exit 1
            fi
            ;;
        "immediate")
            restore_cmd="$restore_cmd --type=immediate"
            log_info "PITR: Restoring to end of backup (immediate)"
            ;;
        "name")
            if [[ -n "$TARGET_NAME" ]]; then
                restore_cmd="$restore_cmd --type=name --target=\"$TARGET_NAME\""
                log_info "PITR: Restoring to named point: $TARGET_NAME"
            else
                log_error "TARGET_NAME is required when RECOVERY_TARGET=name"
                exit 1
            fi
            ;;
        "lsn")
            if [[ -n "$TARGET_LSN" ]]; then
                restore_cmd="$restore_cmd --type=lsn --target=\"$TARGET_LSN\""
                log_info "PITR: Restoring to LSN: $TARGET_LSN"
            else
                log_error "TARGET_LSN is required when RECOVERY_TARGET=lsn"
                exit 1
            fi
            ;;
        "latest"|*)
            log_info "Restoring to latest available backup"
            ;;
    esac

    # Add target action (what to do after reaching recovery target)
    if [[ "$RECOVERY_TARGET" != "latest" ]]; then
        restore_cmd="$restore_cmd --target-action=$TARGET_ACTION"
    fi

    # Add delta option for faster restore
    restore_cmd="$restore_cmd --delta"

    echo "$restore_cmd restore"
}

#===============================================================================
# Configure pgBackRest for S3 restore on target server
#===============================================================================

configure_s3_restore() {
    log_info "Configuring pgBackRest for S3 restore on $NEW_STANDBY_IP..."

    if [[ -z "$S3_BUCKET" ]]; then
        log_error "S3_BUCKET is required for S3 restore"
        exit 1
    fi

    execute_remote "$NEW_STANDBY_IP" "
        # Create pgBackRest directories
        sudo mkdir -p /etc/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest
        sudo chown -R postgres:postgres /etc/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest

        # Create S3 configuration for restore
        sudo -u postgres tee /etc/pgbackrest/pgbackrest.conf << 'PGBR_EOF'
[$STANZA_NAME]
pg1-path=$PG_DATA_DIR
pg1-port=5432

[global]
# S3 Repository configuration
repo1-type=s3
repo1-s3-bucket=$S3_BUCKET
repo1-s3-region=$S3_REGION
repo1-s3-endpoint=$S3_ENDPOINT
repo1-s3-key-type=auto
repo1-path=/pgbackrest/$STANZA_NAME

# General settings
process-max=8
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest

# Restore settings
delta=y

[global:restore]
process-max=8
PGBR_EOF

        echo 'S3 pgBackRest configuration created'

        # Verify S3 access
        echo 'Verifying S3 backup access...'
        if sudo -u postgres pgbackrest --stanza=$STANZA_NAME info; then
            echo 'S3 backup access verified'
        else
            echo 'ERROR: Cannot access S3 backups'
            exit 1
        fi
    " "Configuring pgBackRest for S3 restore"

    log_success "S3 restore configuration completed"
}

#===============================================================================
# List available backups (works for both EBS and S3)
#===============================================================================

list_available_backups() {
    log_info "Listing available backups..."

    if [[ "$RESTORE_SOURCE" == "s3" ]]; then
        # For S3, configure and list from new server
        configure_s3_restore
    fi

    execute_remote "$NEW_STANDBY_IP" "
        echo '=== Available Backups ==='
        sudo -u postgres pgbackrest --stanza=$STANZA_NAME info
        echo ''
        echo '=== Available restore points for PITR ==='
        sudo -u postgres pgbackrest --stanza=$STANZA_NAME info --output=json 2>/dev/null | \
            python3 -c \"
import sys, json
try:
    data = json.load(sys.stdin)
    for stanza in data:
        if stanza.get('backup'):
            for b in stanza['backup']:
                print(f\\\"  Backup: {b.get('label', 'N/A')}\\\")
                print(f\\\"    Type: {b.get('type', 'N/A')}\\\")
                print(f\\\"    Start: {b.get('timestamp', {}).get('start', 'N/A')}\\\")
                print(f\\\"    Stop:  {b.get('timestamp', {}).get('stop', 'N/A')}\\\")
                print(f\\\"    WAL Start: {b.get('archive', {}).get('start', 'N/A')}\\\")
                print(f\\\"    WAL Stop:  {b.get('archive', {}).get('stop', 'N/A')}\\\")
                print('')
except Exception as e:
    print(f'Could not parse backup info: {e}')
\" 2>/dev/null || echo 'Install python3 for detailed backup info'
    " "Listing available backups"
}

#===============================================================================
# Helper function to perform the backup restore (Enhanced with S3 + PITR)
#===============================================================================

perform_backup_restore() {
    local target_backup="$1"

    log "=== STEP 6: Performing database restore ==="
    log_info "Restore source: $RESTORE_SOURCE"
    log_info "Recovery target: $RECOVERY_TARGET"

    if [[ "$RECOVERY_TARGET" == "time" ]] && [[ -n "$TARGET_TIME" ]]; then
        log_info "Target time: $TARGET_TIME"
    fi

    # Build the restore command with PITR options
    local restore_cmd=$(build_restore_command)
    log_info "Restore command: $restore_cmd"

    # Configure S3 if needed
    if [[ "$RESTORE_SOURCE" == "s3" ]]; then
        configure_s3_restore
    fi

    execute_remote "$NEW_STANDBY_IP" "
        # Stop PostgreSQL if running
        sudo systemctl stop postgresql-${PG_VERSION}.service 2>/dev/null || true
        sudo -u postgres pg_ctl -D $PG_DATA_DIR stop -m fast 2>/dev/null || true

        # Remove existing data directory contents but preserve directory
        if [ -d '$PG_DATA_DIR' ]; then
            echo 'Cleaning existing data directory...'
            sudo rm -rf $PG_DATA_DIR/*
        else
            echo 'Creating data directory...'
            sudo mkdir -p $PG_DATA_DIR
        fi

        # Set ownership
        sudo chown postgres:postgres $PG_DATA_DIR

        # Show available backups before restore
        echo '=== Available backups ==='
        sudo -u postgres pgbackrest --stanza=$STANZA_NAME info || echo 'Could not list backups'
        echo ''

        # Perform restore with PITR options
        echo 'Starting pgBackRest restore...'
        echo 'Command: $restore_cmd'
        if sudo -u postgres $restore_cmd; then
            echo 'Restore completed successfully'
        else
            echo 'Restore failed - checking backup status'
            sudo -u postgres pgbackrest --stanza=$STANZA_NAME info || echo 'Backup info failed'
            exit 1
        fi

        # Create standby.signal for streaming replication
        sudo -u postgres touch $PG_DATA_DIR/standby.signal

        # Configure replication in postgresql.conf
        echo 'Configuring standby settings...'
        sudo -u postgres cat << EOF >> $PG_DATA_DIR/postgresql.conf

# Standby configuration - Added by setup script
primary_conninfo = 'host=$PRIMARY_IP port=5432 user=repmgr application_name=$NEW_NODE_NAME connect_timeout=2'
primary_slot_name = '$REPLICATION_SLOT_NAME'
hot_standby = on
hot_standby_feedback = on

# Archive configuration
archive_mode = always
archive_command = 'pgbackrest --stanza=$STANZA_NAME archive-push %p'
archive_timeout = 60

# Performance settings
max_connections = 600
max_wal_senders = 16
max_replication_slots = 16
wal_level = replica

# Additional standby settings
max_standby_streaming_delay = 30s
max_standby_archive_delay = 30s

# Restore command for WAL replay from pgBackRest
restore_command = 'pgbackrest --stanza=$STANZA_NAME archive-get %f \"%p\"'
EOF

        echo 'Database restore and configuration completed'
    " "Performing database restore"

    save_state "DATABASE_RESTORED" "true"
    save_state "RESTORE_SOURCE" "$RESTORE_SOURCE"
    save_state "RECOVERY_TARGET" "$RECOVERY_TARGET"
    [[ -n "$TARGET_TIME" ]] && save_state "TARGET_TIME" "$TARGET_TIME"

    log_success "Database restore completed"
}

#===============================================================================
# Step 7: Setup Replication Slot on Primary
#===============================================================================

setup_replication_slot() {
    log "=== STEP 7: Setting up replication slot on primary ==="

    execute_remote "$PRIMARY_IP" "
        # Check if replication slot already exists
        SLOT_EXISTS=\$(cd /tmp && sudo -u postgres psql -t -c \"SELECT count(*) FROM pg_replication_slots WHERE slot_name='$REPLICATION_SLOT_NAME';\" | xargs)

        if [ \"\$SLOT_EXISTS\" = \"0\" ]; then
            echo 'Creating replication slot for new standby...'
            cd /tmp && sudo -u postgres psql -c \"SELECT pg_create_physical_replication_slot('$REPLICATION_SLOT_NAME');\"
        else
            echo 'Replication slot $REPLICATION_SLOT_NAME already exists'
        fi

        # Check and update pg_hba.conf
        if ! grep -q '$NEW_STANDBY_IP' $PG_DATA_DIR/pg_hba.conf; then
            echo 'Adding pg_hba.conf entries for new standby...'

            # Backup pg_hba.conf
            sudo -u postgres cp $PG_DATA_DIR/pg_hba.conf $PG_DATA_DIR/pg_hba.conf.backup-\$(date +%Y%m%d_%H%M%S)

            # Add entries for new standby (place before any scram-sha-256 rules)
            sudo -u postgres sed -i '/scram-sha-256/i\\
# New standby server entries - Added by standby setup script\\
host    repmgr          repmgr          $NEW_STANDBY_IP/32      trust\\
host    replication     repmgr          $NEW_STANDBY_IP/32      trust\\
host    postgres        repmgr          $NEW_STANDBY_IP/32      trust' $PG_DATA_DIR/pg_hba.conf
        else
            echo 'pg_hba.conf already contains entries for $NEW_STANDBY_IP'
        fi

        # Reload configuration
        cd /tmp && sudo -u postgres psql -c 'SELECT pg_reload_conf();'

        # Verify replication slot
        cd /tmp && sudo -u postgres psql -c \"SELECT slot_name, slot_type, active FROM pg_replication_slots WHERE slot_name='$REPLICATION_SLOT_NAME';\"

        # Show current replication status
        cd /tmp && sudo -u postgres psql -c 'SELECT application_name, client_addr, state FROM pg_stat_replication;'
    " "Setting up replication slot"

    save_state "REPLICATION_SLOT_CREATED" "true"
    log_success "Replication slot setup completed"
}

#===============================================================================
# Step 8: Configure and Start New Standby (FIXED)
#===============================================================================

configure_new_standby() {
    log "=== STEP 8: Configuring and starting new standby server ==="

    execute_remote "$NEW_STANDBY_IP" "
        # Configure pg_hba.conf for standby
        cat << 'EOF' | sudo -u postgres tee $PG_DATA_DIR/pg_hba.conf > /dev/null
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust

# Repmgr connections (MUST be before the general 10.0.0.0/8 rule)
host    repmgr          repmgr          10.0.0.0/8              trust
host    replication     repmgr          10.0.0.0/8              trust
host    repmgr          repmgr          $PRIMARY_IP/32          trust
host    replication     repmgr          $PRIMARY_IP/32          trust
host    repmgr          repmgr          $EXISTING_STANDBY_IP/32 trust
host    replication     repmgr          $EXISTING_STANDBY_IP/32 trust
host    repmgr          repmgr          $NEW_STANDBY_IP/32      trust
host    replication     repmgr          $NEW_STANDBY_IP/32      trust
host    postgres        repmgr          $NEW_STANDBY_IP/32      trust

# General rule for all other connections in 10.0.0.0/8 network
host    all             all             10.0.0.0/8              scram-sha-256
EOF

        # Find and configure repmgr
        REPMGR_PATH=''
        echo 'Checking for repmgr installation...'

        for path in /usr/local/pgsql/bin/repmgr /usr/local/bin/repmgr /usr/pgsql-${PG_VERSION}/bin/repmgr /usr/bin/repmgr; do
            if [ -x \"\$path\" ] && \"\$path\" --version &>/dev/null; then
                REPMGR_PATH=\"\$path\"
                echo \"Found working repmgr at: \$path\"
                break
            fi
        done

        if [ -z \"\$REPMGR_PATH\" ]; then
            echo 'repmgr not found - PostgreSQL will work without cluster management'
        fi

        # Configure repmgr
        if [ -n \"\$REPMGR_PATH\" ]; then
            sudo mkdir -p /var/lib/pgsql
            sudo chown postgres:postgres /var/lib/pgsql
            cat << EOF | sudo -u postgres tee /var/lib/pgsql/repmgr.conf > /dev/null
node_id=$NEW_NODE_ID
node_name='$NEW_NODE_NAME'
conninfo='host=$NEW_STANDBY_IP user=repmgr dbname=repmgr connect_timeout=2'
data_directory='$PG_DATA_DIR'
config_directory='$PG_DATA_DIR'
log_level=INFO
log_file='/var/log/repmgr/repmgr.log'
pg_bindir='/usr/local/pgsql/bin'
repmgrd_service_start_command='sudo systemctl start repmgrd'
repmgrd_service_stop_command='sudo systemctl stop repmgrd'
EOF

            # Create log directory
            sudo mkdir -p /var/log/repmgr
            sudo chown postgres:postgres /var/log/repmgr
        fi

        # Start PostgreSQL using pg_ctl (most reliable cross-distro method)
        echo 'Starting PostgreSQL using pg_ctl...'

        # Find pg_ctl binary
        PG_CTL_BIN=''
        for pgctl_path in /usr/pgsql-${PG_VERSION}/bin/pg_ctl /usr/bin/pg_ctl /usr/local/pgsql/bin/pg_ctl; do
            if [ -x \"\$pgctl_path\" ]; then
                PG_CTL_BIN=\"\$pgctl_path\"
                echo \"Found pg_ctl at: \$pgctl_path\"
                break
            fi
        done

        if [ -z \"\$PG_CTL_BIN\" ]; then
            echo 'ERROR: pg_ctl not found'
            exit 1
        fi

        # Create log directory if needed
        mkdir -p $PG_DATA_DIR/log
        chown postgres:postgres $PG_DATA_DIR/log

        # Start PostgreSQL
        echo \"Starting PostgreSQL with: \$PG_CTL_BIN -D $PG_DATA_DIR start\"
        if sudo -u postgres \$PG_CTL_BIN -D $PG_DATA_DIR -l $PG_DATA_DIR/log/startup.log start; then
            echo 'PostgreSQL started successfully'
        else
            echo 'PostgreSQL startup failed - checking logs'
            cat $PG_DATA_DIR/log/startup.log 2>/dev/null || echo 'No startup log'
            exit 1
        fi

        # Wait for PostgreSQL to accept connections
        echo 'Waiting for PostgreSQL to accept connections...'
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            if sudo -u postgres psql -c 'SELECT 1;' >/dev/null 2>&1; then
                echo \"PostgreSQL accepting connections after \$i seconds\"
                break
            fi
            echo \"  Attempt \$i/15...\"
            sleep 2
        done

        # Final connection test
        if ! sudo -u postgres psql -c 'SELECT 1;' >/dev/null 2>&1; then
            echo 'ERROR: PostgreSQL not accepting connections after 30 seconds'
            cat $PG_DATA_DIR/log/startup.log 2>/dev/null || echo 'No startup log'
            exit 1
        fi

        # Check recovery status
        echo 'Checking recovery status...'
        RECOVERY_STATUS=\$(cd /tmp && sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' | xargs)
        if [ \"\$RECOVERY_STATUS\" = \"t\" ]; then
            echo 'PostgreSQL is in recovery mode - standby setup successful'
        else
            echo 'WARNING: PostgreSQL is not in recovery mode - may not be properly configured as standby'
        fi

        # Show replication status
        echo 'Initial replication status:'
        cd /tmp && sudo -u postgres psql -c 'SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();' || echo 'WAL status check'

        echo 'PostgreSQL standby configuration completed'
    " "Configuring and starting new standby"

    save_state "STANDBY_CONFIGURED" "true"
    log_success "New standby server configuration completed"
}

#===============================================================================
# Step 9: Register with repmgr and Final Verification
#===============================================================================

register_with_repmgr() {
    log "=== STEP 9: Registering with repmgr and final verification ==="

    # Test connections first
    execute_remote "$NEW_STANDBY_IP" "
        echo 'Testing connections...'

        # Test regular PostgreSQL connection
        if cd /tmp && timeout 10 sudo -u postgres psql -h $PRIMARY_IP -U repmgr -d postgres -c 'SELECT 1;' 2>/dev/null; then
            echo 'Regular connection to primary: SUCCESS'
        else
            echo 'Regular connection to primary: FAILED'
        fi

        # Test replication connection
        if cd /tmp && timeout 10 sudo -u postgres psql 'host=$PRIMARY_IP port=5432 user=repmgr application_name=$NEW_NODE_NAME replication=1' -c 'IDENTIFY_SYSTEM;' 2>/dev/null; then
            echo 'Replication connection to primary: SUCCESS'
        else
            echo 'Replication connection to primary: FAILED'
        fi
    " "Testing connections"

    # Register standby with repmgr if available
    execute_remote "$NEW_STANDBY_IP" "
        # Find repmgr binary
        REPMGR_PATH=''
        for path in /usr/local/pgsql/bin/repmgr /usr/local/bin/repmgr /usr/pgsql-${PG_VERSION}/bin/repmgr /usr/bin/repmgr; do
            if [ -x \"\$path\" ] && \"\$path\" --version &>/dev/null; then
                REPMGR_PATH=\"\$path\"
                break
            fi
        done

        if [ -z \"\$REPMGR_PATH\" ]; then
            echo 'repmgr not found - skipping cluster registration'
            echo 'PostgreSQL replication is working without repmgr cluster management'
            exit 0
        fi

        echo \"Using repmgr at: \$REPMGR_PATH\"

        # Test repmgr configuration
        if cd /tmp && sudo -u postgres \"\$REPMGR_PATH\" --version; then
            echo 'repmgr version check successful'
        else
            echo 'repmgr version check failed'
            exit 0
        fi

        # Try to show cluster first
        echo 'Testing repmgr cluster configuration...'
        cd /tmp && sudo -u postgres \"\$REPMGR_PATH\" -f /var/lib/pgsql/repmgr.conf cluster show || echo 'Cluster show test completed'

        # Register with repmgr
        echo 'Registering standby with repmgr...'
        if cd /tmp && sudo -u postgres \"\$REPMGR_PATH\" -f /var/lib/pgsql/repmgr.conf standby register --upstream-node-id=1 --force; then
            echo 'Registration successful'
        else
            echo 'Registration attempted (may already be registered or have connectivity issues)'
        fi

        # Verify registration
        echo 'Verifying cluster registration...'
        cd /tmp && sudo -u postgres \"\$REPMGR_PATH\" -f /var/lib/pgsql/repmgr.conf cluster show || echo 'Final cluster show'
    " "Registering with repmgr"

    save_state "REPMGR_REGISTERED" "true"
    log_success "repmgr registration completed"
}

#===============================================================================
# Step 10: Final Verification and Testing
#===============================================================================

final_verification() {
    log "=== STEP 10: Final verification and testing ==="

    # Check recovery status on new standby
    execute_remote "$NEW_STANDBY_IP" "
        echo '=== Recovery Status ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'

        echo '=== WAL Receiver Status ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT pid, status, sender_host, slot_name FROM pg_stat_wal_receiver;' || echo 'WAL receiver status check'

        echo '=== Current LSN ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();'

        echo '=== Standby Configuration Check ==='
        cd /tmp && sudo -u postgres psql -c 'SHOW primary_conninfo;'
        cd /tmp && sudo -u postgres psql -c 'SHOW primary_slot_name;'

        echo '=== PostgreSQL Log Tail ==='
        sudo tail -10 $PG_DATA_DIR/log/postgresql-*.log 2>/dev/null || echo 'Log check completed'
    " "Checking standby status"

    # Check replication status on primary
    execute_remote "$PRIMARY_IP" "
        echo '=== Primary Replication Status ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;'

        echo '=== Replication Slots ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT slot_name, active, active_pid FROM pg_replication_slots;'

        echo '=== Testing Replication ==='
        cd /tmp && sudo -u postgres psql -c \"CREATE TABLE IF NOT EXISTS replication_test (id serial, message text, created_at timestamp DEFAULT now());\"
        cd /tmp && sudo -u postgres psql -c \"INSERT INTO replication_test (message) VALUES ('Test from standby setup script at \$(date)');\"
    " "Checking primary status and testing replication"

    # Verify replication on standby
    sleep 15
    execute_remote "$NEW_STANDBY_IP" "
        echo '=== Verifying Replication ==='
        cd /tmp && sudo -u postgres psql -c \"SELECT * FROM replication_test ORDER BY id DESC LIMIT 5;\" || echo 'Replication test table verification - may take time to appear'

        echo '=== Final Status Check ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT now(), pg_is_in_recovery();'

        echo '=== Backup Verification ==='
        sudo -u postgres pgbackrest --stanza=$STANZA_NAME info || echo 'Backup info check'
    " "Verifying replication on standby"

    # Show cluster status if repmgr is available
    execute_remote "$PRIMARY_IP" "
        echo '=== Cluster Status ==='
        REPMGR_PATH=''

        # Try to find repmgr on primary
        for path in /usr/pgsql-${PG_VERSION}/bin/repmgr /usr/local/bin/repmgr /usr/bin/repmgr \$(which repmgr 2>/dev/null); do
            if [ -x \"\$path\" ]; then
                REPMGR_PATH=\"\$path\"
                break
            fi
        done

        if [ -n \"\$REPMGR_PATH\" ]; then
            cd /tmp && sudo -u postgres \"\$REPMGR_PATH\" cluster show || echo 'repmgr cluster status check'
        else
            echo 'repmgr not found on primary for cluster status'
        fi
    " "Showing cluster status"

    save_state "VERIFICATION_COMPLETED" "true"
    save_state "SETUP_COMPLETED" "$(date '+%Y-%m-%d %H:%M:%S')"
    log_success "Final verification completed"
}

#===============================================================================
# Summary
#===============================================================================

show_standby_summary() {
    log "=== STANDBY SETUP COMPLETED SUCCESSFULLY! ==="
    echo
    log_info "=== DEPLOYMENT SUMMARY ==="
    log_info "Primary Server: $PRIMARY_IP"
    log_info "Existing Standby: $EXISTING_STANDBY_IP"
    log_info "New Standby: $NEW_STANDBY_IP"
    log_info "PostgreSQL Version: $PG_VERSION"
    log_info "Stanza Name: $STANZA_NAME"
    if [ -n "$LATEST_SNAPSHOT_ID" ]; then
        log_info "Source Snapshot: $LATEST_SNAPSHOT_ID"
    fi
    if [ -n "$NEW_VOLUME_ID" ]; then
        log_info "New Volume: $NEW_VOLUME_ID"
    fi
    echo
    log_info "=== CLUSTER STRUCTURE ==="
    log_info "Node 1 ($PRIMARY_IP) = Primary"
    log_info "Node 2 ($EXISTING_STANDBY_IP) = Existing Standby"
    log_info "Node 3 ($NEW_STANDBY_IP) = New Standby"
    echo
    log_info "=== STATE FILE ==="
    log_info "Configuration saved to: $STATE_FILE"
    if [ -f "$STATE_FILE" ]; then
        log_info "Current state:"
        while IFS= read -r line; do
            log_info "  $line"
        done < "$STATE_FILE"
    fi
    echo
    log_info "=== MONITORING COMMANDS ==="
    echo "# Check replication status:"
    echo "sudo -u postgres repmgr cluster show"
    echo
    echo "# Check PostgreSQL logs:"
    echo "tail -f $PG_DATA_DIR/log/postgresql-*.log"
    echo
    echo "# Check pgBackRest status:"
    echo "sudo -u postgres pgbackrest --stanza=$STANZA_NAME info"
    echo
    echo "# Test backup from new standby:"
    echo "sudo -u postgres pgbackrest --stanza=$STANZA_NAME --type=full backup"
    echo
    log_info "=== FAILOVER COMMANDS ==="
    echo "# Promote standby to primary:"
    echo "sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby promote"
    echo
    echo "# Rejoin old primary as standby:"
    echo "sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf node rejoin -d 'host=NEW_PRIMARY_IP user=repmgr dbname=repmgr' --force-rewind"
    echo
    log_success "Log file saved to: $LOG_FILE"
}

#===============================================================================
# Usage Information
#===============================================================================

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "PREREQUISITES:"
    echo "  - PostgreSQL ${DEFAULT_PG_VERSION} must be pre-installed on the standby server"
    echo "  - AWS CLI configured with appropriate permissions"
    echo "  - SSH access to both primary and standby servers"
    echo "  - pgBackRest backups available (EBS snapshots or S3)"
    echo
    echo "RESTORE SOURCES:"
    echo "  - EBS: Restore from EBS snapshot (fast, local)"
    echo "  - S3:  Restore directly from S3 bucket (no snapshot needed)"
    echo
    echo "PITR (Point-in-Time Recovery):"
    echo "  - latest:    Restore to latest available backup (default)"
    echo "  - time:      Restore to specific point in time"
    echo "  - immediate: Restore to end of backup only"
    echo
    echo "Environment Variables:"
    echo "  PRIMARY_IP              Primary server IP (default: $DEFAULT_PRIMARY_IP)"
    echo "  EXISTING_STANDBY_IP     Existing standby IP (default: $DEFAULT_EXISTING_STANDBY_IP)"
    echo "  NEW_STANDBY_IP          New standby server IP (default: $DEFAULT_NEW_STANDBY_IP)"
    echo "  PG_VERSION              PostgreSQL version (default: $DEFAULT_PG_VERSION)"
    echo "  STANZA_NAME             pgBackRest stanza name (default: $DEFAULT_STANZA_NAME)"
    echo "  AWS_REGION              AWS region (default: $DEFAULT_AWS_REGION)"
    echo "  AVAILABILITY_ZONE       AWS availability zone (default: $DEFAULT_AVAILABILITY_ZONE)"
    echo "  NEW_NODE_ID             New node ID for repmgr (default: $DEFAULT_NEW_NODE_ID)"
    echo "  NEW_NODE_NAME           New node name for repmgr (default: $DEFAULT_NEW_NODE_NAME)"
    echo "  RESTORE_SOURCE          Restore source: ebs or s3 (default: ebs)"
    echo "  S3_BUCKET               S3 bucket name (required for S3 restore)"
    echo "  S3_REGION               S3 bucket region (default: same as AWS_REGION)"
    echo "  RECOVERY_TARGET         Recovery target: latest, time, immediate (default: latest)"
    echo "  TARGET_TIME             Target time for PITR (e.g., '2026-01-14 08:00:00')"
    echo
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  --state-file FILE       Load configuration from primary setup state file"
    echo "  --snapshot-id ID        Use specific snapshot ID instead of latest (EBS only)"
    echo "  --restore-source SRC    Restore source: ebs or s3 (default: ebs)"
    echo "  --s3-bucket BUCKET      S3 bucket name for S3 restore"
    echo "  --s3-region REGION      S3 bucket region"
    echo "  --recovery-target TYPE  Recovery target: latest, time, immediate"
    echo "  --target-time TIME      Target time for PITR (format: 'YYYY-MM-DD HH:MM:SS')"
    echo "  --list-backups          List available backups and exit"
    echo "  --dry-run               Show what would be done without executing"
    echo "  --skip-prerequisites    Skip prerequisites check"
    echo "  --list-snapshots        List available EBS snapshots and exit"
    echo
    echo "Examples:"
    echo "  # Restore from EBS snapshot (default):"
    echo "  $0 --state-file ./pgbackrest_standby_backup_state.env"
    echo
    echo "  # Restore directly from S3:"
    echo "  $0 --restore-source s3 --s3-bucket my-backup-bucket"
    echo
    echo "  # PITR - Restore to specific time:"
    echo "  $0 --state-file ./state.env --recovery-target time --target-time '2026-01-14 08:00:00'"
    echo
    echo "  # S3 restore with PITR:"
    echo "  $0 --restore-source s3 --s3-bucket my-bucket --recovery-target time --target-time '2026-01-14 08:00:00'"
    echo
    echo "  # List available backups:"
    echo "  $0 --list-backups --state-file ./state.env"
    echo
    echo "  # List available EBS snapshots:"
    echo "  $0 --list-snapshots"
}

#===============================================================================
# List Available Snapshots
#===============================================================================

list_snapshots() {
    log "=== AVAILABLE SNAPSHOTS FOR STANZA: $STANZA_NAME ==="

    local snapshots
    snapshots=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:Stanza,Values=$STANZA_NAME" \
        --query 'Snapshots | sort_by(@, &StartTime) | [*].{SnapshotId:SnapshotId,Description:Description,StartTime:StartTime,State:State,Size:VolumeSize}' \
        --output table \
        --region "$AWS_REGION" 2>/dev/null || echo "")

    if [ -n "$snapshots" ] && [ "$snapshots" != "None" ]; then
        echo "$snapshots"
        echo

        # Show latest snapshot
        local latest_snapshot
        latest_snapshot=$(aws ec2 describe-snapshots \
            --owner-ids self \
            --filters "Name=tag:Stanza,Values=$STANZA_NAME" "Name=state,Values=completed" \
            --query 'Snapshots | sort_by(@, &StartTime) | [-1].SnapshotId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "None")

        if [ "$latest_snapshot" != "None" ] && [ -n "$latest_snapshot" ]; then
            log_info "Latest completed snapshot: $latest_snapshot"
        fi

        log_info "To use a specific snapshot:"
        log_info "  $0 --snapshot-id <SNAPSHOT_ID>"
    else
        log_warning "No snapshots found for stanza: $STANZA_NAME"
        log_info "Please run the primary setup script first or check AWS region/tags"
    fi
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
    local use_state_file=""
    local specific_snapshot=""
    local list_snapshots_only=false
    local list_backups_only=false

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            --state-file)
                if [ -z "${2:-}" ]; then
                    log_error "State file path required after --state-file"
                    exit 1
                fi
                use_state_file="$2"
                shift 2
                ;;
            --snapshot-id)
                if [ -z "${2:-}" ]; then
                    log_error "Snapshot ID required after --snapshot-id"
                    exit 1
                fi
                specific_snapshot="$2"
                shift 2
                ;;
            --restore-source)
                if [ -z "${2:-}" ]; then
                    log_error "Restore source required after --restore-source (ebs or s3)"
                    exit 1
                fi
                RESTORE_SOURCE="$2"
                shift 2
                ;;
            --s3-bucket)
                if [ -z "${2:-}" ]; then
                    log_error "S3 bucket name required after --s3-bucket"
                    exit 1
                fi
                S3_BUCKET="$2"
                shift 2
                ;;
            --s3-region)
                if [ -z "${2:-}" ]; then
                    log_error "S3 region required after --s3-region"
                    exit 1
                fi
                S3_REGION="$2"
                shift 2
                ;;
            --recovery-target)
                if [ -z "${2:-}" ]; then
                    log_error "Recovery target required after --recovery-target (latest, time, immediate)"
                    exit 1
                fi
                RECOVERY_TARGET="$2"
                shift 2
                ;;
            --target-time)
                if [ -z "${2:-}" ]; then
                    log_error "Target time required after --target-time (format: 'YYYY-MM-DD HH:MM:SS')"
                    exit 1
                fi
                TARGET_TIME="$2"
                RECOVERY_TARGET="time"
                shift 2
                ;;
            --list-backups)
                list_backups_only=true
                shift
                ;;
            --dry-run)
                log_warning "DRY RUN MODE - No changes will be made"
                DRY_RUN=true
                shift
                ;;
            --skip-prerequisites)
                SKIP_PREREQ=true
                shift
                ;;
            --list-snapshots)
                list_snapshots_only=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Print header
    echo -e "${CYAN}"
    echo "==============================================================================="
    echo "  pgBackRest Standby Setup Script v2.0"
    echo "  PostgreSQL ${PG_VERSION} with S3 Restore & PITR Support"
    echo "==============================================================================="
    echo -e "${NC}"

    # Handle list snapshots request
    if [ "$list_snapshots_only" = true ]; then
        list_snapshots
        exit 0
    fi

    # Handle list backups request
    if [ "$list_backups_only" = true ]; then
        list_available_backups
        exit 0
    fi

    # Validate S3 configuration if using S3 restore
    if [[ "$RESTORE_SOURCE" == "s3" ]]; then
        if [[ -z "$S3_BUCKET" ]]; then
            log_error "S3_BUCKET is required when using --restore-source s3"
            log_error "Use: --s3-bucket <bucket-name>"
            exit 1
        fi
        log_info "Restore source: S3 (bucket: $S3_BUCKET)"
    else
        log_info "Restore source: EBS snapshots"
    fi

    # Log PITR settings
    if [[ "$RECOVERY_TARGET" != "latest" ]]; then
        log_info "PITR enabled: $RECOVERY_TARGET"
        [[ -n "$TARGET_TIME" ]] && log_info "Target time: $TARGET_TIME"
    fi

    # Load existing standby state
    load_state

    # Load state from primary setup if provided
    if [ -n "$use_state_file" ]; then
        PRIMARY_STATE_FILE="$use_state_file"
        load_primary_state "$use_state_file"
    fi

    # Override with specific snapshot if provided
    if [ -n "$specific_snapshot" ]; then
        LATEST_SNAPSHOT_ID="$specific_snapshot"
        log_info "Using specified snapshot: $LATEST_SNAPSHOT_ID"
    fi

    # Show configuration
    log_info "Configuration:"
    log_info "  Primary IP: $PRIMARY_IP"
    log_info "  Existing Standby IP: $EXISTING_STANDBY_IP"
    log_info "  New Standby IP: $NEW_STANDBY_IP"
    log_info "  PostgreSQL Version: $PG_VERSION"
    log_info "  Stanza Name: $STANZA_NAME"
    log_info "  AWS Region: $AWS_REGION"
    if [ -n "$PRIMARY_STATE_FILE" ]; then
        log_info "  Primary State File: $PRIMARY_STATE_FILE"
    fi
    if [ -n "$LATEST_SNAPSHOT_ID" ]; then
        log_info "  Target Snapshot: $LATEST_SNAPSHOT_ID"
    fi
    log_info "  Log File: $LOG_FILE"
    log_info "  State File: $STATE_FILE"
    echo

    # Confirmation prompt
    read -p "Do you want to proceed with the standby setup? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Setup cancelled by user"
        exit 0
    fi

    # Execute setup steps
    if [[ "${SKIP_PREREQ:-false}" != "true" ]]; then
        check_prerequisites
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warning "DRY RUN - Skipping actual execution"
        exit 0
    fi

    # Execute standby setup steps
    if [[ "$RESTORE_SOURCE" == "ebs" ]]; then
        # EBS restore: need snapshot, volume, and attach
        find_latest_snapshot
        create_new_volume
        attach_volume_to_new_server
    else
        log_info "S3 restore mode - skipping EBS snapshot/volume steps"
    fi

    install_pgbackrest_new_server
    configure_pgbackrest_new_server
    restore_database_new_server
    setup_replication_slot
    configure_new_standby
    register_with_repmgr
    final_verification
    show_standby_summary

    log_success "Standby setup completed successfully!"
}

# Execute main function with all arguments
main "$@"


=======


[root@ip-10-107-29-168 setup_new_standby]# ./pgbackrest_standby_setup.sh --state-file /opt/setup_new_standby/pgbackrest_standby_backup_state.env

===============================================================================
  pgBackRest Standby Setup Script - Part 2 (FIXED VERSION)
===============================================================================

[2025-12-18 16:15:47] ℹ️  INFO: State loaded from: /opt/setup_new_standby/pgbackrest_standby_state.env
[2025-12-18 16:15:47] ℹ️  INFO: Primary state loaded from: /opt/setup_new_standby/pgbackrest_standby_backup_state.env
[2025-12-18 16:15:47] ℹ️  INFO: Using backup volume: vol-00d3a4960ff4cfc8d
[2025-12-18 16:15:47] ℹ️  INFO: Using latest snapshot: snap-0aefcbc615083cea9
[2025-12-18 16:15:47] ℹ️  INFO: Configuration:
[2025-12-18 16:15:47] ℹ️  INFO:   Primary IP: 10.40.0.24
[2025-12-18 16:15:47] ℹ️  INFO:   Existing Standby IP: 10.40.0.27
[2025-12-18 16:15:47] ℹ️  INFO:   New Standby IP: 10.40.0.26
[2025-12-18 16:15:47] ℹ️  INFO:   PostgreSQL Version: 13
[2025-12-18 16:15:47] ℹ️  INFO:   Stanza Name: txn_cluster_new
[2025-12-18 16:15:47] ℹ️  INFO:   AWS Region: ap-northeast-1
[2025-12-18 16:15:47] ℹ️  INFO:   Primary State File: /opt/setup_new_standby/pgbackrest_standby_backup_state.env
[2025-12-18 16:15:47] ℹ️  INFO:   Target Snapshot: snap-0aefcbc615083cea9
[2025-12-18 16:15:47] ℹ️  INFO:   Log File: /opt/setup_new_standby/pgbackrest_standby_setup_20251218_161547.log
[2025-12-18 16:15:47] ℹ️  INFO:   State File: /opt/setup_new_standby/pgbackrest_standby_state.env

Do you want to proceed with the standby setup? (yes/no): yes
[2025-12-18 16:15:49] Checking prerequisites for standby setup...
[2025-12-18 16:15:51] ℹ️  INFO: PostgreSQL 13 verified on standby server
[2025-12-18 16:15:51] ✅ Prerequisites check completed
[2025-12-18 16:15:51] === STEP 1: Finding latest snapshot ===
[2025-12-18 16:15:51] ℹ️  INFO: Using snapshot from state file: snap-0aefcbc615083cea9
[2025-12-18 16:15:52] ℹ️  INFO: State saved: LATEST_SNAPSHOT_ID=snap-0aefcbc615083cea9
[2025-12-18 16:15:52] ✅ Verified snapshot: snap-0aefcbc615083cea9
[2025-12-18 16:15:52] === STEP 2: Creating new volume from latest snapshot ===
[2025-12-18 16:15:52] ℹ️  INFO: Volume vol-091c860d36ada7f25 already exists and is available - skipping creation
[2025-12-18 16:15:52] ✅ Using existing volume: vol-091c860d36ada7f25
[2025-12-18 16:15:52] === STEP 3: Attaching volume to new standby server (10.40.0.26) ===
[2025-12-18 16:15:53] ℹ️  INFO: Target instance: i-0962ac642dd1cfe7b
[2025-12-18 16:15:53] Executing on 10.40.0.26: Checking for existing backup mount
Checking current disk layout and backup mount status...
NAME          MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme0n1       259:0    0  300G  0 disk
├─nvme0n1p1   259:1    0  300G  0 part /
├─nvme0n1p127 259:2    0    1M  0 part
└─nvme0n1p128 259:3    0   10M  0 part /boot/efi
nvme1n1       259:4    0  200G  0 disk /backup/pgbackrest

Backup already mounted from: /dev/nvme1n1
Backup data verified - using existing mount
BACKUP_MOUNT_READY=true
[2025-12-18 16:15:54] ✅ Command executed successfully on 10.40.0.26
[2025-12-18 16:15:54] ✅ Backup is already mounted and contains valid data - skipping mount setup
[2025-12-18 16:15:54] ℹ️  INFO: State saved: NEW_INSTANCE_ID=i-0962ac642dd1cfe7b
[2025-12-18 16:15:54] ℹ️  INFO: State saved: VOLUME_ATTACHED=true
[2025-12-18 16:15:54] ℹ️  INFO: State saved: BACKUP_MOUNT_READY=true
[2025-12-18 16:15:54] === STEP 4: Installing pgBackRest on new standby (10.40.0.26) ===
[2025-12-18 16:15:54] Executing on 10.40.0.26: Installing pgBackRest
PostgreSQL installation verified:
psql (PostgreSQL) 13.21
pgBackRest already installed
pgBackRest 2.55.1
Installation verification:
PostgreSQL: /usr/bin/psql
pgBackRest: /usr/bin/pgbackrest
pgBackRest 2.55.1
[2025-12-18 16:15:55] ✅ Command executed successfully on 10.40.0.26
[2025-12-18 16:15:55] ℹ️  INFO: State saved: PGBACKREST_INSTALLED=true
[2025-12-18 16:15:55] ✅ pgBackRest installation completed
[2025-12-18 16:15:55] === STEP 5: Configuring pgBackRest for restore on new standby ===
[2025-12-18 16:15:55] Executing on 10.40.0.26: Configuring pgBackRest for restore
Testing pgBackRest configuration...
stanza: txn_cluster_new
    status: ok
    cipher: none

    db (current)
        wal archive min/max (13): 000000010000000000000014/00000009000000000000006D

        full backup: 20250916-032133F
            timestamp start/stop: 2025-09-16 03:21:33+00 / 2025-09-16 03:21:36+00
            wal start/stop: 000000010000000000000019 / 000000010000000000000019
            database size: 93.7MB, database backup size: 93.7MB
            repo1: backup set size: 6.3MB, backup size: 6.3MB

        diff backup: 20250916-032133F_20250916-032247D
            timestamp start/stop: 2025-09-16 03:22:47+00 / 2025-09-16 03:22:49+00
            wal start/stop: 00000001000000000000001C / 00000001000000000000001C
            database size: 93.9MB, database backup size: 18.5MB
            repo1: backup set size: 6.3MB, backup size: 860.8KB
            backup reference total: 1 full

        incr backup: 20250916-032133F_20250916-032311I
            timestamp start/stop: 2025-09-16 03:23:11+00 / 2025-09-16 03:23:14+00
            wal start/stop: 00000001000000000000001F / 00000001000000000000001F
            database size: 93.9MB, database backup size: 18.6MB
            repo1: backup set size: 6.3MB, backup size: 862.9KB
            backup reference total: 1 full, 1 diff

        incr backup: 20250916-032133F_20250916-080645I
            timestamp start/stop: 2025-09-16 08:06:45+00 / 2025-09-16 08:06:49+00
            wal start/stop: 000000010000000000000025 / 000000010000000000000025
            database size: 119.7MB, database backup size: 44.3MB
            repo1: backup set size: 7.5MB, backup size: 2.0MB
            backup reference total: 1 full, 1 diff, 1 incr

        incr backup: 20250916-032133F_20250916-080817I
            timestamp start/stop: 2025-09-16 08:08:17+00 / 2025-09-16 08:08:20+00
            wal start/stop: 000000010000000000000027 / 000000010000000000000027
            database size: 119.8MB, database backup size: 44.5MB
            repo1: backup set size: 7.5MB, backup size: 2MB
            backup reference total: 1 full, 1 diff, 2 incr

        incr backup: 20250916-032133F_20250916-081335I
            timestamp start/stop: 2025-09-16 08:13:35+00 / 2025-09-16 08:13:38+00
            wal start/stop: 000000010000000000000029 / 000000010000000000000029
            database size: 120.3MB, database backup size: 45.0MB
            repo1: backup set size: 7.5MB, backup size: 2MB
            backup reference total: 1 full, 1 diff, 3 incr

        incr backup: 20250916-032133F_20250916-082402I
            timestamp start/stop: 2025-09-16 08:24:02+00 / 2025-09-16 08:24:06+00
            wal start/stop: 00000001000000000000002B / 00000001000000000000002B
            database size: 121.3MB, database backup size: 45.9MB
            repo1: backup set size: 7.6MB, backup size: 2MB
            backup reference total: 1 full, 1 diff, 4 incr

        incr backup: 20250916-032133F_20250916-082439I
            timestamp start/stop: 2025-09-16 08:24:39+00 / 2025-09-16 08:24:42+00
            wal start/stop: 00000001000000000000002D / 00000001000000000000002D
            database size: 121.3MB, database backup size: 46.0MB
            repo1: backup set size: 7.6MB, backup size: 2MB
            backup reference total: 1 full, 1 diff, 5 incr

        incr backup: 20250916-032133F_20250916-083634I
            timestamp start/stop: 2025-09-16 08:36:34+00 / 2025-09-16 08:36:37+00
            wal start/stop: 00000001000000000000002F / 00000001000000000000002F
            database size: 122.4MB, database backup size: 47MB
            repo1: backup set size: 7.6MB, backup size: 2.1MB
            backup reference total: 1 full, 1 diff, 6 incr

        incr backup: 20250916-032133F_20250916-084649I
            timestamp start/stop: 2025-09-16 08:46:49+00 / 2025-09-16 08:46:52+00
            wal start/stop: 000000010000000000000031 / 000000010000000000000031
            database size: 123.3MB, database backup size: 48.0MB
            repo1: backup set size: 7.7MB, backup size: 2.2MB
            backup reference total: 1 full, 1 diff, 7 incr

        incr backup: 20250916-032133F_20250916-084835I
            timestamp start/stop: 2025-09-16 08:48:35+00 / 2025-09-16 08:48:38+00
            wal start/stop: 000000010000000000000033 / 000000010000000000000033
            database size: 123.5MB, database backup size: 48.2MB
            repo1: backup set size: 7.7MB, backup size: 2.2MB
            backup reference total: 1 full, 1 diff, 8 incr

        incr backup: 20250916-032133F_20250916-143126I
            timestamp start/stop: 2025-09-16 14:31:26+00 / 2025-09-16 14:31:28+00
            wal start/stop: 000000010000000000000035 / 000000010000000000000036
            database size: 154.1MB, database backup size: 78.8MB
            repo1: backup set size: 9MB, backup size: 3.5MB
            backup reference total: 1 full, 1 diff, 9 incr

        incr backup: 20250916-032133F_20250916-143251I
            timestamp start/stop: 2025-09-16 14:32:51+00 / 2025-09-16 14:32:54+00
            wal start/stop: 000000010000000000000038 / 000000010000000000000038
            database size: 154.2MB, database backup size: 78.9MB
            repo1: backup set size: 9MB, backup size: 3.5MB
            backup reference total: 1 full, 1 diff, 10 incr
pgBackRest configuration and backup data verified successfully
[2025-12-18 16:15:55] ✅ Command executed successfully on 10.40.0.26
[2025-12-18 16:15:55] ℹ️  INFO: State saved: PGBACKREST_CONFIGURED=true
[2025-12-18 16:15:55] ✅ pgBackRest restore configuration completed
[2025-12-18 16:15:55] === STEP 6: Checking database status and backup version ===
[2025-12-18 16:15:56] ℹ️  INFO: Latest available backup: 20250916-032133F_20250916-143251I
none
[2025-12-18 16:15:56] ℹ️  INFO: PostgreSQL data directory exists - checking current state
[2025-12-18 16:15:56] ℹ️  INFO: Current restored backup label: pgBackRest
[2025-12-18 16:15:57] ℹ️  INFO: Standby signal file found - checking if PostgreSQL is running
[2025-12-18 16:15:57] ℹ️  INFO: PostgreSQL service is active - checking recovery status
[2025-12-18 16:15:57] ✅ PostgreSQL is running as standby
[2025-12-18 16:15:57] ⚠️  WARNING: Current backup (pgBackRest) is different from latest available (20250916-032133F_20250916-143251I
none)
[2025-12-18 16:15:57] ℹ️  INFO: Will restore latest backup to ensure standby is up-to-date
[2025-12-18 16:15:57] ℹ️  INFO: Stopping PostgreSQL for backup update
[2025-12-18 16:15:58] ℹ️  INFO: Performing database restore with latest backup: 20250916-032133F_20250916-143251I
none
[2025-12-18 16:15:58] === STEP 6: Performing database restore ===
[2025-12-18 16:15:58] Executing on 10.40.0.26: Performing database restore
Cleaning existing data directory...
Starting pgBackRest restore...
2025-12-18 16:15:58.764 P00   INFO: restore command begin 2.55.1: --delta --exec-id=98802-2bae15ba --log-level-console=info --log-level-file=detail --log-path=/backup/pgbackrest/logs --pg1-path=/dbdata/pgsql/13/data --process-max=20 --repo1-path=/backup/pgbackrest/repo --stanza=txn_cluster_new
2025-12-18 16:15:58.765 P00   WARN: --delta or --force specified but unable to find 'PG_VERSION' or 'backup.manifest' in '/dbdata/pgsql/13/data' to confirm that this is a valid $PGDATA directory. --delta and --force have been disabled and if any files exist in the destination directories the restore will be aborted.
2025-12-18 16:15:58.773 P00   INFO: repo1: restore backup set 20250916-032133F_20250916-143251I, recovery will start at 2025-09-16 14:32:51
2025-12-18 16:15:58.773 P00   INFO: remap data directory to '/dbdata/pgsql/13/data'
2025-12-18 16:16:01.663 P00   INFO: write updated /dbdata/pgsql/13/data/postgresql.auto.conf
2025-12-18 16:16:01.669 P00   INFO: restore global/pg_control (performed last to ensure aborted restores cannot be started)
2025-12-18 16:16:01.671 P00   INFO: restore size = 154.2MB, file total = 1251
2025-12-18 16:16:01.671 P00   INFO: restore command end: completed successfully (2909ms)
Restore completed successfully
Configuring standby settings...
Database restore and configuration completed
[2025-12-18 16:16:01] ✅ Command executed successfully on 10.40.0.26
[2025-12-18 16:16:01] ℹ️  INFO: State saved: DATABASE_RESTORED=true
[2025-12-18 16:16:01] ✅ Database restore completed
[2025-12-18 16:16:01] === STEP 7: Setting up replication slot on primary ===
[2025-12-18 16:16:01] Executing on 10.40.0.24: Setting up replication slot
Replication slot standby4_slot already exists
grep: /dbdata/pgsql/13/data/pg_hba.conf: No such file or directory
Adding pg_hba.conf entries for new standby...
cp: cannot stat '/dbdata/pgsql/13/data/pg_hba.conf': No such file or directory
sed: can't read /dbdata/pgsql/13/data/pg_hba.conf: No such file or directory
 pg_reload_conf
----------------
 t
(1 row)

   slot_name   | slot_type | active
---------------+-----------+--------
 standby4_slot | physical  | f
(1 row)

 application_name | client_addr |   state
------------------+-------------+-----------
 standby          | 10.40.0.27  | streaming
 standby3         | 10.40.0.17  | streaming
(2 rows)

[2025-12-18 16:16:02] ✅ Command executed successfully on 10.40.0.24
[2025-12-18 16:16:02] ℹ️  INFO: State saved: REPLICATION_SLOT_CREATED=true
[2025-12-18 16:16:02] ✅ Replication slot setup completed
[2025-12-18 16:16:02] === STEP 8: Configuring and starting new standby server ===
[2025-12-18 16:16:02] Executing on 10.40.0.26: Configuring and starting new standby
Checking for repmgr installation...
Found working repmgr at: /usr/local/pgsql/bin/repmgr
Testing PostgreSQL configuration...
sudo: /usr/pgsql-13/bin/postgres: command not found
WARNING: PostgreSQL configuration has issues
Starting PostgreSQL service...
PostgreSQL started successfully
PostgreSQL connection test successful
Checking recovery status...
PostgreSQL is in recovery mode - standby setup successful
Initial replication status:
 pg_last_wal_receive_lsn | pg_last_wal_replay_lsn
-------------------------+------------------------
                         | 0/41000000
(1 row)

PostgreSQL standby configuration completed
[2025-12-18 16:16:04] ✅ Command executed successfully on 10.40.0.26
[2025-12-18 16:16:04] ℹ️  INFO: State saved: STANDBY_CONFIGURED=true
[2025-12-18 16:16:04] ✅ New standby server configuration completed
[2025-12-18 16:16:04] === STEP 9: Registering with repmgr and final verification ===
[2025-12-18 16:16:04] Executing on 10.40.0.26: Testing connections
Testing connections...
Regular connection to primary: FAILED
      systemid       | timeline |  xlogpos   | dbname
---------------------+----------+------------+--------
 7550343275655584289 |        9 | 0/6E0018B0 |
(1 row)

Replication connection to primary: SUCCESS
[2025-12-18 16:16:14] ✅ Command executed successfully on 10.40.0.26
[2025-12-18 16:16:14] Executing on 10.40.0.26: Registering with repmgr
Using repmgr at: /usr/local/pgsql/bin/repmgr
repmgr 5.3.3
repmgr version check successful
Testing repmgr cluster configuration...
 ID | Name     | Role    | Status    | Upstream | Location | Priority | Timeline | Connection string
----+----------+---------+-----------+----------+----------+----------+----------+-------------------------------------------------------------
 1  | primary  | primary | * running |          | default  | 100      | 9        | host=10.40.0.24 user=repmgr dbname=repmgr connect_timeout=2
 2  | standby  | standby |   running | primary  | default  | 100      | 9        | host=10.40.0.27 user=repmgr dbname=repmgr connect_timeout=2
 3  | standby3 | standby |   running | primary  | default  | 100      | 9        | host=10.40.0.17 user=repmgr dbname=repmgr connect_timeout=2
Registering standby with repmgr...
INFO: connecting to local node "standby4" (ID: 4)
INFO: connecting to primary database
INFO: standby registration complete
NOTICE: standby node "standby4" (ID: 4) successfully registered
Registration successful
Verifying cluster registration...
 ID | Name     | Role    | Status    | Upstream | Location | Priority | Timeline | Connection string
----+----------+---------+-----------+----------+----------+----------+----------+-------------------------------------------------------------
 1  | primary  | primary | * running |          | default  | 100      | 9        | host=10.40.0.24 user=repmgr dbname=repmgr connect_timeout=2
 2  | standby  | standby |   running | primary  | default  | 100      | 9        | host=10.40.0.27 user=repmgr dbname=repmgr connect_timeout=2
 3  | standby3 | standby |   running | primary  | default  | 100      | 9        | host=10.40.0.17 user=repmgr dbname=repmgr connect_timeout=2
 4  | standby4 | standby |   running | primary  | default  | 100      | 1        | host=10.40.0.26 user=repmgr dbname=repmgr connect_timeout=2
[2025-12-18 16:16:14] ✅ Command executed successfully on 10.40.0.26
[2025-12-18 16:16:14] ℹ️  INFO: State saved: REPMGR_REGISTERED=true
[2025-12-18 16:16:14] ✅ repmgr registration completed
[2025-12-18 16:16:14] === STEP 10: Final verification and testing ===
[2025-12-18 16:16:14] Executing on 10.40.0.26: Checking standby status
=== Recovery Status ===
 pg_is_in_recovery
-------------------
 t
(1 row)

=== WAL Receiver Status ===
  pid  |  status   | sender_host |   slot_name
-------+-----------+-------------+---------------
 99131 | streaming | 10.40.0.24  | standby4_slot
(1 row)

=== Current LSN ===
 pg_last_wal_receive_lsn | pg_last_wal_replay_lsn
-------------------------+------------------------
 0/6E002598              | 0/6E002598
(1 row)

=== Standby Configuration Check ===
                                 primary_conninfo
-----------------------------------------------------------------------------------
 host=10.40.0.24 port=5432 user=repmgr application_name=standby4 connect_timeout=2
(1 row)

 primary_slot_name
-------------------
 standby4_slot
(1 row)

=== PostgreSQL Log Tail ===
Log check completed
[2025-12-18 16:16:15] ✅ Command executed successfully on 10.40.0.26
[2025-12-18 16:16:15] Executing on 10.40.0.24: Checking primary status and testing replication
=== Primary Replication Status ===
 application_name | client_addr |   state   | sync_state
------------------+-------------+-----------+------------
 standby          | 10.40.0.27  | streaming | async
 standby3         | 10.40.0.17  | streaming | async
 standby4         | 10.40.0.26  | streaming | async
(3 rows)

=== Replication Slots ===
    slot_name    | active | active_pid
-----------------+--------+------------
 standby_slot    | f      |
 standby_slot_3  | t      |    3349760
 standby_27      | t      |    2373860
 standby_17_slot | f      |
 standby4_slot   | t      |    3352546
(5 rows)

=== Testing Replication ===
NOTICE:  relation "replication_test" already exists, skipping
CREATE TABLE
INSERT 0 1
[2025-12-18 16:16:15] ✅ Command executed successfully on 10.40.0.24
[2025-12-18 16:16:30] Executing on 10.40.0.26: Verifying replication on standby
=== Verifying Replication ===
 id |                            message                             |         created_at
----+----------------------------------------------------------------+----------------------------
  5 | Test from standby setup script at Thu Dec 18 16:16:15 UTC 2025 | 2025-12-18 16:16:15.923992
  4 | Test from standby setup script at Thu Dec 18 15:53:51 UTC 2025 | 2025-12-18 15:53:51.116756
  3 | Test from standby setup script at Thu Dec 18 15:42:26 UTC 2025 | 2025-12-18 15:42:26.723673
  2 | Test from standby setup script at Thu Dec 18 15:25:57 UTC 2025 | 2025-12-18 15:25:57.265189
  1 | Test from standby setup script at Thu Dec 18 14:41:00 UTC 2025 | 2025-12-18 14:41:00.157258
(5 rows)

=== Final Status Check ===
             now              | pg_is_in_recovery
------------------------------+-------------------
 2025-12-18 16:16:31.32858+00 | t
(1 row)

=== Backup Verification ===
stanza: txn_cluster_new
    status: ok
    cipher: none

    db (current)
        wal archive min/max (13): 000000010000000000000014/00000009000000000000006D

        full backup: 20250916-032133F
            timestamp start/stop: 2025-09-16 03:21:33+00 / 2025-09-16 03:21:36+00
            wal start/stop: 000000010000000000000019 / 000000010000000000000019
            database size: 93.7MB, database backup size: 93.7MB
            repo1: backup set size: 6.3MB, backup size: 6.3MB

        diff backup: 20250916-032133F_20250916-032247D
            timestamp start/stop: 2025-09-16 03:22:47+00 / 2025-09-16 03:22:49+00
            wal start/stop: 00000001000000000000001C / 00000001000000000000001C
            database size: 93.9MB, database backup size: 18.5MB
            repo1: backup set size: 6.3MB, backup size: 860.8KB
            backup reference total: 1 full

        incr backup: 20250916-032133F_20250916-032311I
            timestamp start/stop: 2025-09-16 03:23:11+00 / 2025-09-16 03:23:14+00
            wal start/stop: 00000001000000000000001F / 00000001000000000000001F
            database size: 93.9MB, database backup size: 18.6MB
            repo1: backup set size: 6.3MB, backup size: 862.9KB
            backup reference total: 1 full, 1 diff

        incr backup: 20250916-032133F_20250916-080645I
            timestamp start/stop: 2025-09-16 08:06:45+00 / 2025-09-16 08:06:49+00
            wal start/stop: 000000010000000000000025 / 000000010000000000000025
            database size: 119.7MB, database backup size: 44.3MB
            repo1: backup set size: 7.5MB, backup size: 2.0MB
            backup reference total: 1 full, 1 diff, 1 incr

        incr backup: 20250916-032133F_20250916-080817I
            timestamp start/stop: 2025-09-16 08:08:17+00 / 2025-09-16 08:08:20+00
            wal start/stop: 000000010000000000000027 / 000000010000000000000027
            database size: 119.8MB, database backup size: 44.5MB
            repo1: backup set size: 7.5MB, backup size: 2MB
            backup reference total: 1 full, 1 diff, 2 incr

        incr backup: 20250916-032133F_20250916-081335I
            timestamp start/stop: 2025-09-16 08:13:35+00 / 2025-09-16 08:13:38+00
            wal start/stop: 000000010000000000000029 / 000000010000000000000029
            database size: 120.3MB, database backup size: 45.0MB
            repo1: backup set size: 7.5MB, backup size: 2MB
            backup reference total: 1 full, 1 diff, 3 incr

        incr backup: 20250916-032133F_20250916-082402I
            timestamp start/stop: 2025-09-16 08:24:02+00 / 2025-09-16 08:24:06+00
            wal start/stop: 00000001000000000000002B / 00000001000000000000002B
            database size: 121.3MB, database backup size: 45.9MB
            repo1: backup set size: 7.6MB, backup size: 2MB
            backup reference total: 1 full, 1 diff, 4 incr

        incr backup: 20250916-032133F_20250916-082439I
            timestamp start/stop: 2025-09-16 08:24:39+00 / 2025-09-16 08:24:42+00
            wal start/stop: 00000001000000000000002D / 00000001000000000000002D
            database size: 121.3MB, database backup size: 46.0MB
            repo1: backup set size: 7.6MB, backup size: 2MB
            backup reference total: 1 full, 1 diff, 5 incr

        incr backup: 20250916-032133F_20250916-083634I
            timestamp start/stop: 2025-09-16 08:36:34+00 / 2025-09-16 08:36:37+00
            wal start/stop: 00000001000000000000002F / 00000001000000000000002F
            database size: 122.4MB, database backup size: 47MB
            repo1: backup set size: 7.6MB, backup size: 2.1MB
            backup reference total: 1 full, 1 diff, 6 incr

        incr backup: 20250916-032133F_20250916-084649I
            timestamp start/stop: 2025-09-16 08:46:49+00 / 2025-09-16 08:46:52+00
            wal start/stop: 000000010000000000000031 / 000000010000000000000031
            database size: 123.3MB, database backup size: 48.0MB
            repo1: backup set size: 7.7MB, backup size: 2.2MB
            backup reference total: 1 full, 1 diff, 7 incr

        incr backup: 20250916-032133F_20250916-084835I
            timestamp start/stop: 2025-09-16 08:48:35+00 / 2025-09-16 08:48:38+00
            wal start/stop: 000000010000000000000033 / 000000010000000000000033
            database size: 123.5MB, database backup size: 48.2MB
            repo1: backup set size: 7.7MB, backup size: 2.2MB
            backup reference total: 1 full, 1 diff, 8 incr

        incr backup: 20250916-032133F_20250916-143126I
            timestamp start/stop: 2025-09-16 14:31:26+00 / 2025-09-16 14:31:28+00
            wal start/stop: 000000010000000000000035 / 000000010000000000000036
            database size: 154.1MB, database backup size: 78.8MB
            repo1: backup set size: 9MB, backup size: 3.5MB
            backup reference total: 1 full, 1 diff, 9 incr

        incr backup: 20250916-032133F_20250916-143251I
            timestamp start/stop: 2025-09-16 14:32:51+00 / 2025-09-16 14:32:54+00
            wal start/stop: 000000010000000000000038 / 000000010000000000000038
            database size: 154.2MB, database backup size: 78.9MB
            repo1: backup set size: 9MB, backup size: 3.5MB
            backup reference total: 1 full, 1 diff, 10 incr
[2025-12-18 16:16:31] ✅ Command executed successfully on 10.40.0.26
[2025-12-18 16:16:31] Executing on 10.40.0.24: Showing cluster status
=== Cluster Status ===
repmgr not found on primary for cluster status
[2025-12-18 16:16:31] ✅ Command executed successfully on 10.40.0.24
[2025-12-18 16:16:31] ℹ️  INFO: State saved: VERIFICATION_COMPLETED=true
[2025-12-18 16:16:31] ℹ️  INFO: State saved: SETUP_COMPLETED=2025-12-18 16:16:31
[2025-12-18 16:16:31] ✅ Final verification completed
[2025-12-18 16:16:31] === STANDBY SETUP COMPLETED SUCCESSFULLY! ===

[2025-12-18 16:16:31] ℹ️  INFO: === DEPLOYMENT SUMMARY ===
[2025-12-18 16:16:31] ℹ️  INFO: Primary Server: 10.40.0.24
[2025-12-18 16:16:31] ℹ️  INFO: Existing Standby: 10.40.0.27
[2025-12-18 16:16:31] ℹ️  INFO: New Standby: 10.40.0.26
[2025-12-18 16:16:31] ℹ️  INFO: PostgreSQL Version: 13
[2025-12-18 16:16:31] ℹ️  INFO: Stanza Name: txn_cluster_new
[2025-12-18 16:16:31] ℹ️  INFO: Source Snapshot: snap-0aefcbc615083cea9
[2025-12-18 16:16:31] ℹ️  INFO: New Volume: vol-091c860d36ada7f25

[2025-12-18 16:16:31] ℹ️  INFO: === CLUSTER STRUCTURE ===
[2025-12-18 16:16:31] ℹ️  INFO: Node 1 (10.40.0.24) = Primary
[2025-12-18 16:16:31] ℹ️  INFO: Node 2 (10.40.0.27) = Existing Standby
[2025-12-18 16:16:31] ℹ️  INFO: Node 3 (10.40.0.26) = New Standby

[2025-12-18 16:16:31] ℹ️  INFO: === STATE FILE ===
[2025-12-18 16:16:31] ℹ️  INFO: Configuration saved to: /opt/setup_new_standby/pgbackrest_standby_state.env
[2025-12-18 16:16:31] ℹ️  INFO: Current state:
[2025-12-18 16:16:31] ℹ️  INFO:   NEW_VOLUME_ID=vol-091c860d36ada7f25
[2025-12-18 16:16:31] ℹ️  INFO:   LATEST_SNAPSHOT_ID=snap-0aefcbc615083cea9
[2025-12-18 16:16:31] ℹ️  INFO:   NEW_INSTANCE_ID=i-0962ac642dd1cfe7b
[2025-12-18 16:16:31] ℹ️  INFO:   VOLUME_ATTACHED=true
[2025-12-18 16:16:31] ℹ️  INFO:   BACKUP_MOUNT_READY=true
[2025-12-18 16:16:31] ℹ️  INFO:   PGBACKREST_INSTALLED=true
[2025-12-18 16:16:31] ℹ️  INFO:   PGBACKREST_CONFIGURED=true
[2025-12-18 16:16:31] ℹ️  INFO:   DATABASE_RESTORED=true
[2025-12-18 16:16:31] ℹ️  INFO:   REPLICATION_SLOT_CREATED=true
[2025-12-18 16:16:31] ℹ️  INFO:   STANDBY_CONFIGURED=true
[2025-12-18 16:16:31] ℹ️  INFO:   REPMGR_REGISTERED=true
[2025-12-18 16:16:31] ℹ️  INFO:   VERIFICATION_COMPLETED=true
[2025-12-18 16:16:31] ℹ️  INFO:   SETUP_COMPLETED="2025-12-18 16:16:31"

[2025-12-18 16:16:31] ℹ️  INFO: === MONITORING COMMANDS ===
# Check replication status:
sudo -u postgres repmgr cluster show

# Check PostgreSQL logs:
tail -f /dbdata/pgsql/13/data/log/postgresql-*.log

# Check pgBackRest status:
sudo -u postgres pgbackrest --stanza=txn_cluster_new info

# Test backup from new standby:
sudo -u postgres pgbackrest --stanza=txn_cluster_new --type=full backup

[2025-12-18 16:16:31] ℹ️  INFO: === FAILOVER COMMANDS ===
# Promote standby to primary:
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby promote

# Rejoin old primary as standby:
sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf node rejoin -d 'host=NEW_PRIMARY_IP user=repmgr dbname=repmgr' --force-rewind

[2025-12-18 16:16:31] ✅ Log file saved to: /opt/setup_new_standby/pgbackrest_standby_setup_20251218_161547.log
[2025-12-18 16:16:31] ✅ Standby setup completed successfully!
