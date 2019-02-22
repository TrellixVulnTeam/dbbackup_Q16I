#!/bin/bash

set -e
set -o pipefail

source /common.sh

DAYS_TO_KEEP=${DAYS_TO_KEEP:-30}
BACKUP_DIR=${BACKUP_DIR:-}
BACKUP_SUFFIX=${BACKUP_SUFFIX:-}
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_USER=${MYSQL_USER:-root}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-root}
PROMETHEUS_PUSHGATEWAY_URL=${PROMETHEUS_PUSHGATEWAY_URL:-}

function help() {
	echo "$0"
	echo "	-h prints help"
	echo "	Environment variables:"
	echo "		DAYS_TO_KEEP: number of days after which old backup files will be deleted"
	echo "		BACKUP_SUFFIX: suffix of the backup file"
	echo "		BACKUP_DIR: output directory"
	echo "		MYSQL_HOST: mysql hostname"
	echo "		MYSQL_USER: mysql username"
	echo "		MYSQL_PASSWORD: mysql user password"
}

function pre_checks() {
	if [ -z "$BACKUP_DIR" ]; then
		log "BACKUP_DIR is required but not found. Exiting."
		exit 1
	fi
    mkdir -p "$BACKUP_DIR"
    endsWithSlash "$BACKUP_DIR" || BACKUP_DIR="${BACKUP_DIR}/"
}

function prune_old_backups() {
    log "Deleting old backups"
	find $BACKUP_DIR -maxdepth 1 -type f -mtime +$DAYS_TO_KEEP -name "*${BACKUP_SUFFIX}.sql.gz" -exec echo '{}' \; -exec rm -rf '{}' \;
    log "Deleting old backups done"
}

function push_metrics() {
	if [ -n "$PROMETHEUS_PUSHGATEWAY_URL" ]; then
	# Labels (key/values) in URL (after job/jobname) are used as grouping key
cat <<EOT | curl --silent --data-binary @- "$PROMETHEUS_PUSHGATEWAY_URL/metrics/job/$1-$2/host/$1" || log "Failed to push metrics to pushgateway at $PROMETHEUS_PUSHGATEWAY_URL" && true
# TYPE database_backup_file_size gauge
database_backup_file_size{database="$2", label="Backup file size in Kilobytes"} $3
EOT
		if [[ "$?" -ne 0 ]]; then
			log "Failed to push metrics to pushgateway at $PROMETHEUS_PUSHGATEWAY_URL"
		fi
	fi
}

function perform_backups() {
    log "Starting backup of all databases"

    local suffix=$1
    suffix="`date +\%Y-\%m-\%d-\%H\%M\%S`$suffix"

	local databases # in two steps to catch eventual errors (otherwise return code is code of local assignment)
	databases=$(/usr/bin/mysql -h $MYSQL_HOST -u $MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema)")
	for database in $databases; do
		backup_filename="${BACKUP_DIR}${database}_${suffix}.sql.gz"
		log "Backup database ${database} to ${backup_filename}"
		if ! /usr/bin/mysqldump -h $MYSQL_HOST -u $MYSQL_USER -p$MYSQL_PASSWORD --databases $database | gzip > "${backup_filename}"; then
			log "Failed to backup database ${database}"
			exit 1
		fi
		log "mysqldump retcode $?"
		log "Backup done"
		size=$(du -k ${backup_filename} | cut -f -1)
		log "database: $database - size (KB): $size - file: ${backup_filename}" # Use cut to only show bytes (no filename)
		push_metrics "$MYSQL_HOST" "$database" "$size"
	done
    log "Backup of all databases done"
}

function main() {
	if [ "$1" = "-h" ]; then
		help
		exit 0
	fi
	pre_checks
	prune_old_backups
    perform_backups "$BACKUP_SUFFIX"
}

log "Starting MySQL backup"
main
