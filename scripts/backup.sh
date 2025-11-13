#!/bin/sh
set -e

# Configuration
DB_HOST="database"
DB_USER="${POSTGRES_USER:-postgres}"
DB_NAME="${POSTGRES_DB:-image_classification}"
BACKUP_DIR="/backups"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

echo "[INFO] Initializing automated backup service"
echo "[INFO] Configuration: backup_dir=$BACKUP_DIR, retention_days=$RETENTION_DAYS, interval=600s"

# Function to perform backup
perform_backup() {
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/backup_${DB_NAME}_${TIMESTAMP}.sql.gz"
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting backup..."
    
    # Perform backup with compression
    if pg_dump -h "$DB_HOST" -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_FILE"; then
        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Backup completed: file=$BACKUP_FILE, size=$BACKUP_SIZE"
        
        # Verify backup integrity
        if gunzip -t "$BACKUP_FILE" 2>/dev/null; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Backup integrity check passed"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Backup integrity check failed: file may be corrupted"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Backup operation failed"
        return 1
    fi
    
    # Cleanup old backups
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Executing retention policy: max_age=${RETENTION_DAYS}d"
    DELETED=$(find "$BACKUP_DIR" -name "backup_*.sql.gz" -type f -mtime "+$RETENTION_DAYS" -delete -print | wc -l)
    if [ "$DELETED" -gt 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Retention cleanup: deleted=$DELETED"
    fi
    
    # Display backup statistics
    TOTAL_BACKUPS=$(find "$BACKUP_DIR" -name "backup_*.sql.gz" -type f | wc -l)
    TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Backup statistics: count=$TOTAL_BACKUPS, total_size=$TOTAL_SIZE"
}

# Wait for database to be ready
echo "[INFO] Waiting for database connection: host=$DB_HOST, user=$DB_USER"
until pg_isready -h "$DB_HOST" -U "$DB_USER" >/dev/null 2>&1; do
    echo "[WARN] Database unavailable, retrying in 5s"
    sleep 5
done
echo "[INFO] Database connection established"

perform_backup

# Schedule backups every 10 minutes
BACKUP_INTERVAL=600  # 10 minutes in seconds
while true; do
    NEXT_BACKUP=$(date -d "+${BACKUP_INTERVAL} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v+${BACKUP_INTERVAL}S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "in 10 minutes")
    
    echo "[INFO] Next backup scheduled: time=$NEXT_BACKUP, interval=${BACKUP_INTERVAL}s"
    sleep "$BACKUP_INTERVAL"
    
    perform_backup
done