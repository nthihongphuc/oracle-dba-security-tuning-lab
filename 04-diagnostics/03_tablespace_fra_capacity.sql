-- ============================================================================
-- File:        04-diagnostics/03_tablespace_fra_capacity.sql
-- Purpose:     Oracle 19c/23ai Day-2 Capacity & Storage Triage — Tablespace
--              Autoextend Headroom, Active TEMP Sort Consumers, Fast Recovery
--              Area (FRA) Saturation (ORA-19809 prevention), and Hourly Redo
--              Log Switch Frequency (24h window).
-- Safety:      STRICTLY READ-ONLY (SELECT queries only; zero DDL/DML changes).
-- Multitenant: Tablespace & TEMP queries are scoped to FREEPDB1; FRA and Redo
--              Logs are CDB/instance-wide resources (CON_ID = 0) shared by all
--              PDBs — saturation impacts FREEPDB1 immediately.
-- Execution:   Run as SYSDBA or a DBA diagnostic account with SELECT_CATALOG_ROLE:
--                sqlplus / as sysdba @/opt/lab/04-diagnostics/03_tablespace_fra_capacity.sql
-- ============================================================================

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET LINESIZE 240
SET PAGESIZE 100
SET TAB OFF
SET TRIMSPOOL ON
SET FEEDBACK ON
SET VERIFY OFF
SET SERVEROUTPUT OFF

-- Explicitly switch into target Pluggable Database
ALTER SESSION SET CONTAINER = FREEPDB1;

SHOW CON_NAME
SHOW CON_ID

COLUMN tablespace_name          FORMAT A24
COLUMN contents                 FORMAT A12
COLUMN status                   FORMAT A10
COLUMN bigfile                  FORMAT A7
COLUMN used_mb                  FORMAT 999,999,990.00
COLUMN max_mb                   FORMAT 999,999,990.00
COLUMN headroom_mb              FORMAT 999,999,990.00
COLUMN used_percent             FORMAT 990.00
COLUMN alert_tier               FORMAT A12
COLUMN con_id                   FORMAT 999
COLUMN sid                      FORMAT 99999
COLUMN serial#                  FORMAT 999999
COLUMN username                 FORMAT A16
COLUMN program                  FORMAT A26 TRUNC
COLUMN tablespace               FORMAT A18
COLUMN segtype                  FORMAT A10
COLUMN sql_id                   FORMAT A13
COLUMN temp_mb                  FORMAT 999,990.00
COLUMN fra_dest                 FORMAT A44 TRUNC
COLUMN limit_mb                 FORMAT 999,999,990.00
COLUMN reclaimable_mb           FORMAT 999,999,990.00
COLUMN gross_used_pct           FORMAT 990.00
COLUMN effective_used_pct       FORMAT 990.00
COLUMN fra_alert_tier           FORMAT A28
COLUMN file_type                FORMAT A24
COLUMN percent_space_used       FORMAT 990.00
COLUMN percent_space_reclaimable FORMAT 990.00
COLUMN switch_hour              FORMAT A16
COLUMN switches_per_hr          FORMAT 999,990
COLUMN sizing_advisory          FORMAT A38

-- ============================================================================
-- QUERY 1: Tablespace Capacity & Autoextend Headroom
--          Uses dba_tablespace_usage_metrics (reflects AUTOEXTEND MAXSIZE)
--          multiplied by exact dba_tablespaces.block_size.
--          Alert thresholds: OK (<80%), WARN (>=80%), CRITICAL (>=90%).
-- ============================================================================
PROMPT ========================================================================
PROMPT [1/4] TABLESPACE CAPACITY & AUTOEXTEND HEADROOM (FREEPDB1)
PROMPT ========================================================================
SELECT m.tablespace_name,
       t.contents,
       t.status,
       t.bigfile,
       ROUND(m.used_space * t.block_size / 1024 / 1024, 2) AS used_mb,
       ROUND(m.tablespace_size * t.block_size / 1024 / 1024, 2) AS max_mb,
       ROUND((m.tablespace_size - m.used_space) * t.block_size / 1024 / 1024, 2) AS headroom_mb,
       ROUND(m.used_percent, 2) AS used_percent,
       CASE
         WHEN m.used_percent >= 90 THEN 'CRITICAL'
         WHEN m.used_percent >= 80 THEN 'WARN'
         ELSE 'OK'
       END AS alert_tier
  FROM dba_tablespace_usage_metrics m
  JOIN dba_tablespaces t
    ON t.tablespace_name = m.tablespace_name
 ORDER BY m.used_percent DESC, m.tablespace_name;

-- ============================================================================
-- QUERY 2: TEMP Tablespace Active Sort / Hash / LOB Consumers
--          Joins v$tempseg_usage.session_addr -> v$session.saddr (CON_ID-safe)
-- ============================================================================
PROMPT ========================================================================
PROMPT [2/4] TEMP TABLESPACE ACTIVE SORT / HASH CONSUMERS (V$TEMPSEG_USAGE)
PROMPT ========================================================================
SELECT u.con_id,
       s.sid,
       s.serial#,
       s.username,
       s.program,
       u.tablespace,
       u.segtype,
       COALESCE(u.sql_id, s.sql_id) AS sql_id,
       SUM(u.extents) AS extents,
       ROUND(SUM(u.blocks * t.block_size) / 1024 / 1024, 2) AS temp_mb
  FROM v$tempseg_usage u
  JOIN v$session s
    ON s.saddr  = u.session_addr
   AND s.con_id = u.con_id
  JOIN dba_tablespaces t
    ON t.tablespace_name = u.tablespace
 WHERE u.con_id = TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'))
 GROUP BY u.con_id,
          s.sid,
          s.serial#,
          s.username,
          s.program,
          u.tablespace,
          u.segtype,
          COALESCE(u.sql_id, s.sql_id)
 ORDER BY temp_mb DESC;

-- ============================================================================
-- QUERY 3: Fast Recovery Area (FRA) Saturation & File-Type Breakdown
--          Prevents ORA-19809 (limit exceeded for recovery files) & archiver
--          hangs (ORA-00257) that freeze all OLTP commits across the CDB.
-- ============================================================================
PROMPT ========================================================================
PROMPT [3A/4] FAST RECOVERY AREA (FRA) SATURATION (V$RECOVERY_FILE_DEST)
PROMPT ========================================================================
SELECT con_id,
       name AS fra_dest,
       ROUND(space_limit / 1024 / 1024, 2) AS limit_mb,
       ROUND(space_used / 1024 / 1024, 2) AS used_mb,
       ROUND(space_reclaimable / 1024 / 1024, 2) AS reclaimable_mb,
       ROUND(100 * space_used / NULLIF(space_limit, 0), 2) AS gross_used_pct,
       ROUND(100 * (space_used - space_reclaimable) / NULLIF(space_limit, 0), 2) AS effective_used_pct,
       number_of_files,
       CASE
         WHEN 100 * (space_used - space_reclaimable) / NULLIF(space_limit, 0) >= 85
           THEN 'CRITICAL (ORA-19809 RISK)'
         WHEN 100 * (space_used - space_reclaimable) / NULLIF(space_limit, 0) >= 75
           THEN 'WARN'
         ELSE 'OK'
       END AS fra_alert_tier
  FROM v$recovery_file_dest;

PROMPT ========================================================================
PROMPT [3B/4] FAST RECOVERY AREA USAGE BY FILE TYPE (V$FLASH_RECOVERY_AREA_USAGE)
PROMPT ========================================================================
SELECT con_id,
       file_type,
       percent_space_used,
       percent_space_reclaimable,
       number_of_files
  FROM v$flash_recovery_area_usage
 ORDER BY percent_space_used DESC, file_type;

-- ============================================================================
-- QUERY 4: Redo Log Switch Frequency per Hour (Last 24 Hours) + Log Sizing
--          Target: <= 4 switches/hour under normal OLTP load; > 12/hr signals
--          undersized redo logs causing excessive checkpointing & log file sync.
-- ============================================================================
PROMPT ========================================================================
PROMPT [4A/4] REDO LOG SWITCH FREQUENCY PER HOUR — LAST 24H (V$LOG_HISTORY)
PROMPT ========================================================================
SELECT thread#,
       TO_CHAR(TRUNC(first_time, 'HH24'), 'YYYY-MM-DD HH24:00') AS switch_hour,
       COUNT(*) AS switches_per_hr,
       CASE
         WHEN COUNT(*) > 12 THEN 'CRITICAL (>12/hr - Undersized Redo)'
         WHEN COUNT(*) > 4  THEN 'WARN (>4/hr - Review Redo Sizing)'
         ELSE 'OK (<=4/hr Target)'
       END AS sizing_advisory
  FROM v$log_history
 WHERE first_time >= SYSDATE - 1
 GROUP BY thread#, TRUNC(first_time, 'HH24')
 ORDER BY TRUNC(first_time, 'HH24') DESC, thread#;

PROMPT ========================================================================
PROMPT [4B/4] ONLINE REDO LOG GROUP SIZING REFERENCE (V$LOG)
PROMPT ========================================================================
SELECT group#,
       thread#,
       sequence#,
       ROUND(bytes / 1024 / 1024, 1) AS size_mb,
       members,
       archived,
       status
  FROM v$log
 ORDER BY thread#, group#;
