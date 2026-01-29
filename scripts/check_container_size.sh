#!/usr/bin/env bash
#
# Diagnostic script to identify what's making docker commit slow
#

if [ "$#" -lt 1 ]; then
  echo "Usage: $(basename "$0") <container-name>"
  exit 1
fi

CONTAINER_NAME="$1"

echo "=== Analyzing container: $CONTAINER_NAME ==="
echo

# 1. Check container size (if docker reports it)
echo "1. Container size info:"
docker ps -s --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Size}}"
echo

# 2. Find largest directories in container
echo "2. Top 10 largest directories in container:"
docker exec "$CONTAINER_NAME" bash -c "du -sh /workspace/* 2>/dev/null | sort -rh | head -10" || echo "  (Could not access /workspace)"
echo

# 3. Check for common build artifacts
echo "3. Checking for build artifacts:"
echo "  Python cache files:"
docker exec "$CONTAINER_NAME" bash -c "find /workspace -type d -name '__pycache__' 2>/dev/null | wc -l" 2>/dev/null || echo "  (Not found or no access)"
echo "  .pyc files:"
docker exec "$CONTAINER_NAME" bash -c "find /workspace -name '*.pyc' 2>/dev/null | wc -l" 2>/dev/null || echo "  (Not found or no access)"
echo "  node_modules:"
docker exec "$CONTAINER_NAME" bash -c "du -sh /workspace/*/node_modules 2>/dev/null" || echo "  (Not found)"
echo

# 4. Check for large log files
echo "4. Large log files (>10MB):"
docker exec "$CONTAINER_NAME" bash -c "find /workspace -name '*.log' -size +10M -exec ls -lh {} \; 2>/dev/null" || echo "  (No large log files found)"
echo

# 5. Check for temporary/cache directories
echo "5. Cache directories:"
docker exec "$CONTAINER_NAME" bash -c "du -sh ~/.cache ~/.pip 2>/dev/null" || echo "  (Not found)"
echo

# 6. Show what would be committed (changes since base image)
echo "6. Filesystem changes (this is what gets committed):"
echo "  Running 'docker diff' to show changed files..."
docker diff "$CONTAINER_NAME" | head -50
echo "  ... (showing first 50 lines)"
echo

echo "=== Recommendations ==="
echo "If commit is slow due to:"
echo "  - Build artifacts: Add .dockerignore with __pycache__, *.pyc, etc."
echo "  - Large logs: Clean them before committing or add to .dockerignore"
echo "  - Large datasets: Consider using volumes instead of storing in container"
echo "  - Many small files: Consider cleaning up temp files before committing"
