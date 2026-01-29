#!/usr/bin/env bash
#
# Syncs a local project directory to a remote server using tar and scp.
# (Docker-related logic removed as per user request)
#
# ======================================================================================
# CONFIGURATION
# ======================================================================================

# Remote Server Configuration
SERVER_IP="${SERVER_IP:-14.103.52.172}"
REMOTE_USER="${REMOTE_USER:-zhw}"

# Local Project Directory
LOCAL_PROJECT_DIR="${LOCAL_PROJECT_DIR:-$HOME/framework/server/}"

# Remote Project Directory (注意：远端用户是 zhw，不是本地用户)
REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR:-/home/zhw/framework/server/}"

# SSH Key Configuration
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"

# Local temporary directory
LOCAL_TMP_DIR="${LOCAL_TMP_DIR:-${TMPDIR:-/tmp/}}"

# Construct target server
TARGET_SERVER="${REMOTE_USER}@${SERVER_IP}"

# ======================================================================================

set -euo pipefail

# ======================================================================================
# ANSI Color Codes
# ======================================================================================
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

# ======================================================================================
# Logging Functions
# ======================================================================================

log() {
  printf "${COLOR_BLUE}[%s]${COLOR_RESET} %s\n" "$(date '+%H:%M:%S')" "$*"
}

log_success() {
  printf "${COLOR_GREEN}[%s] ✓ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*"
}

log_error() {
  printf "${COLOR_RED}[%s] ✗ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*" >&2
}

log_warning() {
  printf "${COLOR_YELLOW}[%s] ⚠ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*"
}

# ======================================================================================
# Usage and Validation
# ======================================================================================

# Check if local directory exists
if [ ! -d "$LOCAL_PROJECT_DIR" ]; then
  log_error "Local directory not found: $LOCAL_PROJECT_DIR"
  exit 1
fi

# Check prerequisites
for cmd in ssh scp tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Command '$cmd' is required but not found in PATH."
    exit 1
  fi
done

# ======================================================================================
# Archive Preparation
# ======================================================================================

# Generate Archive names
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
PROJECT_DIR_NAME="$(basename "$LOCAL_PROJECT_DIR")"
PROJECT_ARCHIVE_NAME="project_${TIMESTAMP}.tar"
REMOTE_PROJECT_ARCHIVE_PATH="$(dirname "${REMOTE_PROJECT_DIR%/}")/${PROJECT_ARCHIVE_NAME}"

# Prepare temporary space
LOCAL_TMP_DIR="${LOCAL_TMP_DIR%/}/"
LOCAL_ARCHIVE_TMP_DIR="$(mktemp -d "${LOCAL_TMP_DIR}deploy_XXXXXX")"

cleanup() {
  local exit_code=$?
  if [ -d "$LOCAL_ARCHIVE_TMP_DIR" ]; then
    rm -rf "$LOCAL_ARCHIVE_TMP_DIR"
  fi
  
  # If transfer was interrupted (non-zero exit), clean up remote archive
  if [ $exit_code -ne 0 ]; then
    log_warning "Transfer interrupted, cleaning up remote server..."
    ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" \
      "rm -f '$(dirname "${REMOTE_PROJECT_DIR%/}")/${PROJECT_ARCHIVE_NAME}' 2>/dev/null || true" || true
  fi
}
trap cleanup EXIT

LOCAL_PROJECT_ARCHIVE_PATH="${LOCAL_ARCHIVE_TMP_DIR}/${PROJECT_ARCHIVE_NAME}"

log ""
log "=========================================="
log "Transfer Codebase"
log "=========================================="
log ""
log "Configuration:"
log "  Local Path:      ${LOCAL_PROJECT_DIR}"
log "  Remote Path:     ${REMOTE_PROJECT_DIR}"
log "  Target Server:   ${TARGET_SERVER}"
log "  SSH Key:         ${SSH_KEY_PATH}"
log ""

# --- Confirmation Prompt (确认提示) ---
echo ""
echo "================================================================================"
echo "  WARNING: This will perform destructive operations on ${TARGET_SERVER}:"
echo "================================================================================"
echo "  - Remove remote directory: ${REMOTE_PROJECT_DIR}"
echo ""
echo "  The following will be deployed:"
echo "  - Project code from: ${LOCAL_PROJECT_DIR}"
echo "================================================================================"
echo ""
read -p "Do you want to proceed? (yes/no): " confirmation
if [ "$confirmation" != "yes" ]; then
  echo "Deployment cancelled."
  exit 0
fi
echo ""

# --- 0. Remote Preparation (远端准备工作) ---
log "0. Preparing remote server..."
ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" \
  "PROJECT_ARCHIVE='${PROJECT_ARCHIVE_NAME}' \
   REMOTE_PROJECT_DIR='${REMOTE_PROJECT_DIR}' \
   bash -s" <<'EOF'
set -euo pipefail

BASE_DIR="$(dirname "${REMOTE_PROJECT_DIR%/}")"
mkdir -p "$BASE_DIR"
PROJECT_ARCHIVE_PATH="${BASE_DIR}/$PROJECT_ARCHIVE"

# --- 0.1 File System Cleanup (按照逻辑强制清理) ---
if [ -d "${REMOTE_PROJECT_DIR%/}" ]; then
    rm -rf "${REMOTE_PROJECT_DIR%/}"
    echo "    [0.1] Removed existing remote directory: ${REMOTE_PROJECT_DIR%/}"
fi

# Clean up any stale project_*.tar archives (including incomplete transfers)
find "$BASE_DIR" -maxdepth 1 -name "project_*.tar" -type f -mtime +0 -delete 2>/dev/null || true
echo "    [0.1] Cleaned up old archive files"

if [ -f "$PROJECT_ARCHIVE_PATH" ]; then
    rm -f "$PROJECT_ARCHIVE_PATH"
    echo "    [0.1] Removed stale archive: $PROJECT_ARCHIVE_PATH"
fi
EOF
log_success "Remote server prepared"

# --- 1. Package Local Project (打包本地项目) ---
log ""
log "1. Packaging local project..."
tar -cf "$LOCAL_PROJECT_ARCHIVE_PATH" -C "$(dirname "$LOCAL_PROJECT_DIR")" \
  --exclude="${PROJECT_DIR_NAME}/shared" \
  "$PROJECT_DIR_NAME"
ARCHIVE_SIZE=$(du -h "$LOCAL_PROJECT_ARCHIVE_PATH" | cut -f1)
log_success "Project packaged [${ARCHIVE_SIZE}] - excluding shared/"

# --- 2. Transfer Archive (传输归档文件) ---
log ""
log "2. Transferring archive to remote server..."
echo "   Archive: ${ARCHIVE_SIZE}"
rsync -avh --progress -e "ssh -i ${SSH_KEY_PATH}" "$LOCAL_PROJECT_ARCHIVE_PATH" "${TARGET_SERVER}:${REMOTE_PROJECT_ARCHIVE_PATH}"
log_success "Archive transferred"

# --- 3. Remote Deployment (远端部署) ---
log ""
log "3. Extracting and deploying on remote server..."
ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" \
  "PROJECT_ARCHIVE='${PROJECT_ARCHIVE_NAME}' \
   PROJECT_DIR_NAME='${PROJECT_DIR_NAME}' \
   REMOTE_PROJECT_DIR='${REMOTE_PROJECT_DIR}' \
   bash -s" <<'EOF'
set -euo pipefail

BASE_DIR="$(dirname "${REMOTE_PROJECT_DIR%/}")"
PROJECT_ARCHIVE_PATH="${BASE_DIR}/$PROJECT_ARCHIVE"
EXTRACTED_PROJECT_PATH="${BASE_DIR}/$PROJECT_DIR_NAME"

# Validate archive
if [ ! -f "$PROJECT_ARCHIVE_PATH" ]; then
  echo "Error: Project archive not found: $PROJECT_ARCHIVE_PATH" >&2
  exit 1
fi

# Extract
tar -xf "$PROJECT_ARCHIVE_PATH" -C "$BASE_DIR"

# Rename if the extracted name doesn't match target path
if [ "$EXTRACTED_PROJECT_PATH" != "${REMOTE_PROJECT_DIR%/}" ]; then
  mv "$EXTRACTED_PROJECT_PATH" "${REMOTE_PROJECT_DIR%/}"
fi

# Cleanup remote archive
rm -f "$PROJECT_ARCHIVE_PATH"
echo "    [3.1] Project extracted to: ${REMOTE_PROJECT_DIR}"
EOF
log_success "Deployment completed"

log ""
log_success "=========================================="
log_success "Transfer completed successfully!"
log_success "=========================================="