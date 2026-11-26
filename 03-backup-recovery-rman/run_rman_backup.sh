#!/usr/bin/env bash
# ==============================================================================
# File:        03-backup-recovery-rman/run_rman_backup.sh
# Purpose:     Production-grade Bash wrapper for Oracle RMAN backups
#              - Enforces single-instance execution lock (prevents cron overlap)
#              - Validates environment & ARCHIVELOG mode before running RMAN
#              - Supports `full` (Level 0) and `inc1` (Level 1) backup modes
#              - Captures structured logs, checks exit codes and ORA-/RMAN- stacks
#              - Enforces 30-day local backup log retention
# Usage:       ./run_rman_backup.sh [full|inc1]
# ==============================================================================

set -euo pipefail
umask 027

BACKUP_MODE="${1:-inc1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configurable environment variables (no hardcoded credentials; uses OS auth '/')
export ORACLE_SID="${ORACLE_SID:-FREE}"
export ORACLE_HOME="${ORACLE_HOME:-/opt/oracle/product/23ai/dbhomeFree}"
export PATH="${ORACLE_HOME}/bin:${PATH}"

RMAN_BACKUP_DIR="${RMAN_BACKUP_DIR:-/opt/oracle/rman_backups}"
RMAN_LOG_DIR="${RMAN_LOG_DIR:-/opt/oracle/rman_logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
LOG_FILE="${RMAN_LOG_DIR}/rman_${BACKUP_MODE}_${ORACLE_SID}_${TIMESTAMP}.log"
LOCK_DIR="${RMAN_LOG_DIR}/.rman_backup_${ORACLE_SID}.lock"

log_info() {
  printf '[%s] [INFO]  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

log_error() {
  printf '[%s] [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

cleanup_lock() {
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}

# 1. Select RMAN command file
case "${BACKUP_MODE}" in
  full)
    RMAN_CMDFILE="${SCRIPT_DIR}/rman_backup_full.rcv"
    ;;
  inc1)
    RMAN_CMDFILE="${SCRIPT_DIR}/rman_backup_inc1.rcv"
    ;;
  *)
    log_error "Invalid backup mode '${BACKUP_MODE}'. Expected 'full' or 'inc1'."
    exit 2
    ;;
esac

if [[ ! -f "${RMAN_CMDFILE}" ]]; then
  log_error "RMAN command file not found: ${RMAN_CMDFILE}"
  exit 2
fi

mkdir -p "${RMAN_BACKUP_DIR}" "${RMAN_LOG_DIR}"

# 2. Prevent overlapping cron executions via atomic lock directory
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  log_error "Another RMAN backup lock is active (${LOCK_DIR}). Aborting to avoid catalog contention."
  exit 5
fi
trap cleanup_lock EXIT

# 3. Verify Oracle binaries exist
if ! command -v sqlplus >/dev/null 2>&1 || ! command -v rman >/dev/null 2>&1; then
  log_error "sqlplus/rman not found in PATH (ORACLE_HOME=${ORACLE_HOME})."
  exit 3
fi

# 4. Pre-flight check: verify instance is reachable and in ARCHIVELOG mode
log_info "Checking LOG_MODE for ORACLE_SID=${ORACLE_SID}..."
if ! LOG_MODE="$(
  sqlplus -s / as sysdba <<'EOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT 9
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF PAGESIZE 0 TRIMSPOOL ON
SELECT log_mode FROM v$database;
EXIT;
EOF
)"; then
  log_error "Pre-flight SQL*Plus check failed for ORACLE_SID=${ORACLE_SID}. Output: ${LOG_MODE}"
  exit 4
fi
LOG_MODE="$(printf '%s' "${LOG_MODE}" | tr -d '[:space:]')"

if [[ "${LOG_MODE}" != "ARCHIVELOG" ]]; then
  log_error "Database ${ORACLE_SID} is in '${LOG_MODE}' mode. Online RMAN backups require ARCHIVELOG mode."
  exit 4
fi

log_info "Pre-flight passed (LOG_MODE=${LOG_MODE}). Starting RMAN '${BACKUP_MODE}' backup..."
log_info "Command file: ${RMAN_CMDFILE}"
log_info "Log file:     ${LOG_FILE}"

# 5. Execute RMAN using OS authentication (never pass plaintext SYS passwords on CLI)
set +e
rman target / cmdfile="${RMAN_CMDFILE}" log="${LOG_FILE}"
RMAN_RC=$?
set -e

# 6. Validate both exit code and log contents for column-0 or indented RMAN-/ORA- errors
if [[ ${RMAN_RC} -ne 0 ]] || grep -Eq '(^|[[:space:]])(RMAN-[0-9]{5}|ORA-[0-9]{5}):' "${LOG_FILE}"; then
  log_error "RMAN backup FAILED (exit_code=${RMAN_RC}). Inspect log: ${LOG_FILE}"
  grep -En '(^|[[:space:]])(RMAN-[0-9]{5}|ORA-[0-9]{5}):' "${LOG_FILE}" | tail -n 20 >&2 || true
  exit 1
fi

log_info "RMAN '${BACKUP_MODE}' backup completed successfully."

# 7. Prune RMAN log files older than retention threshold
find "${RMAN_LOG_DIR}" -type f -name "rman_*.log" -mtime "+${LOG_RETENTION_DAYS}" -delete
log_info "Pruned RMAN logs older than ${LOG_RETENTION_DAYS} days."
