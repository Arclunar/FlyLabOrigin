#!/usr/bin/env bash
#
# Syncs a local project directory to a remote server using tar and scp.
# (Docker-related logic removed as per user request)
#
# ======================================================================================
# CONFIGURATION (Environment Variables)
# ======================================================================================

# Local Directory to sync (本地项目路径)
LOCAL_PROJECT_DIR="${LOCAL_PROJECT_DIR:-$HOME/framework/server/}"

# Remote Directory to sync to (远端存放路径)
REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR:-/data/nvme_data/rec_ws/server/}"

# Local temporary directory root (本地临时目录)
LOCAL_TMP_DIR="${LOCAL_TMP_DIR:-$HOME/Public/}"

# SSH Key Configuration (SSH密钥配置)
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"

# ======================================================================================

set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

if [ "$#" -lt 1 ]; then
  cat <<EOF
Usage: $(basename "$0") <target-server>

Arguments:
  target-server    Remote server name (rec-server, wu, ali)

Environment Variables:
  LOCAL_PROJECT_DIR    Local project path to sync
                       Default: \$HOME/server/
  REMOTE_PROJECT_DIR   Remote destination path
                       Default: /data/nvme_data/rec_ws/server/
  LOCAL_TMP_DIR        Local temporary directory root
                       Default: \$HOME/Public/
  SSH_KEY_PATH         SSH key path for authentication
                       Default: \$HOME/.ssh/id_ed25519

Example:
  $(basename "$0") rec-server
  LOCAL_PROJECT_DIR=/custom/path $(basename "$0") rec-server
EOF
  exit 1
fi

TARGET_SERVER="$1"
case "$TARGET_SERVER" in
  rec-server|wu|ali)
    ;;
  *)
    echo "Unsupported target server: $TARGET_SERVER" >&2
    exit 1
    ;;
esac

# Check if local directory exists
if [ ! -d "$LOCAL_PROJECT_DIR" ]; then
  echo "Error: Local directory not found: $LOCAL_PROJECT_DIR" >&2
  exit 1
fi

# Check prerequisites
for cmd in ssh scp tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: Command '$cmd' is required but not found in PATH." >&2
    exit 1
  fi
done

# Generate Archive names
HOST_SLUG="$(echo "$TARGET_SERVER" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g')"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
PROJECT_DIR_NAME="$(basename "$LOCAL_PROJECT_DIR")"
PROJECT_ARCHIVE_NAME="project_${HOST_SLUG}_${TIMESTAMP}.tar"
REMOTE_PROJECT_ARCHIVE_PATH="$(dirname "${REMOTE_PROJECT_DIR%/}")/${PROJECT_ARCHIVE_NAME}"

# Prepare temporary space
mkdir -p "$LOCAL_TMP_DIR"
LOCAL_ARCHIVE_TMP_DIR="$(mktemp -d "${LOCAL_TMP_DIR%/}/deploy_XXXXXX")"

cleanup() {
  if [ -d "$LOCAL_ARCHIVE_TMP_DIR" ]; then
    rm -rf "$LOCAL_ARCHIVE_TMP_DIR"
  fi
}
trap cleanup EXIT

LOCAL_PROJECT_ARCHIVE_PATH="${LOCAL_ARCHIVE_TMP_DIR}/${PROJECT_ARCHIVE_NAME}"

log "Configuration:"
log "  Local Path:      ${LOCAL_PROJECT_DIR}"
log "  Remote Path:     ${REMOTE_PROJECT_DIR}"
log "  Target Server:   ${TARGET_SERVER}"
log "  SSH Key Path:    ${SSH_KEY_PATH}"

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
log "0. Preparing remote server ${TARGET_SERVER}..."
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

if [ -f "$PROJECT_ARCHIVE_PATH" ]; then
    rm -f "$PROJECT_ARCHIVE_PATH"
    echo "    [0.1] Removed stale archive: $PROJECT_ARCHIVE_PATH"
fi
EOF

# --- 1. Package Local Project (打包本地项目) ---
log "1. Packaging local project to ${LOCAL_PROJECT_ARCHIVE_PATH}..."
tar -cf "$LOCAL_PROJECT_ARCHIVE_PATH" -C "$(dirname "$LOCAL_PROJECT_DIR")" "$PROJECT_DIR_NAME"

# --- 2. Transfer Archive (传输归档文件) ---
log "2. Transferring project archive to ${TARGET_SERVER}..."
scp -i "$SSH_KEY_PATH" "$LOCAL_PROJECT_ARCHIVE_PATH" "${TARGET_SERVER}:${REMOTE_PROJECT_ARCHIVE_PATH}"

# --- 3. Remote Deployment (远端部署) ---
log "3. Extracting project on ${TARGET_SERVER}..."
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

log "Deployment to ${TARGET_SERVER} completed successfully."