-- ============================================================================
-- File:        04-diagnostics/01_top_sql_and_waits.sql
-- Purpose:     Oracle 19c/23ai Day-2 Incident Triage — Top SQL, Non-Idle Wait
--              Events, Shared Pool Literal-SQL Hard-Parse Pressure & PGA/SGA
--              Memory Advisory Snapshot (Multitenant CON_ID-Aware).
-- Safety:      STRICTLY READ-ONLY (SELECT queries only; zero DDL/DML changes).
-- Execution:   Run as SYSDBA or a DBA diagnostic account with SELECT_CATALOG_ROLE:
--                sqlplus / as sysdba @/opt/lab/04-diagnostics/01_top_sql_and_waits.sql
-- ============================================================================

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET LINESIZE 240
SET PAGESIZE 100
SET TAB OFF
SET TRIMSPOOL ON
SET FEEDBACK ON
SET VERIFY OFF
SET SERVEROUTPUT OFF

-- Explicitly switch into target Pluggable Database (never query blind in CDB$ROOT)
ALTER SESSION SET CONTAINER = FREEPDB1;

SHOW CON_NAME
SHOW CON_ID

COLUMN con_id               FORMAT 999
COLUMN sql_id               FORMAT A13
COLUMN child_number         FORMAT 999     HEADING 'CHILD#'
COLUMN parsing_schema_name  FORMAT A16     HEADING 'SCHEMA'
COLUMN executions           FORMAT 999,999,990
COLUMN total_elapsed_sec    FORMAT 999,990.00
COLUMN avg_elapsed_ms       FORMAT 999,990.00
COLUMN buffer_gets          FORMAT 999,999,999,990
COLUMN buffer_gets_per_exec FORMAT 999,999,990.0
COLUMN disk_reads           FORMAT 999,999,990
COLUMN rows_processed       FORMAT 999,999,990
COLUMN sql_text_preview     FORMAT A72     TRUNC
COLUMN wait_class           FORMAT A18
COLUMN event                FORMAT A42     TRUNC
COLUMN total_waits          FORMAT 999,999,990
COLUMN total_timeouts       FORMAT 999,999,990
COLUMN time_waited_sec      FORMAT 999,990.00
COLUMN avg_wait_ms          FORMAT 999,990.00
COLUMN pct_db_wait_time     FORMAT 990.00  HEADING 'PCT_WAIT'
COLUMN force_matching_sig   FORMAT A22     HEADING 'FORCE_MATCHING_SIG'
COLUMN sample_schema        FORMAT A16
COLUMN sample_sql_id        FORMAT A13
COLUMN sample_sql_text      FORMAT A68     TRUNC
COLUMN name                 FORMAT A46
COLUMN metric_value         FORMAT 999,999,990.00
COLUMN metric_unit          FORMAT A10
COLUMN component            FORMAT A34
COLUMN last_oper_type       FORMAT A14
COLUMN last_oper_time       FORMAT A19

-- ============================================================================
-- QUERY 1: Top 15 SQL Statements by Elapsed Time & Buffer Gets (V$SQL)
--          Excludes internal Oracle-maintained schemas (SYS, SYSMAN, etc.)
-- ============================================================================
PROMPT ========================================================================
PROMPT [1/4] TOP 15 SQL BY ELAPSED TIME & BUFFER GETS (V$SQL, CON_ID-SCOPED)
PROMPT ========================================================================
SELECT /* DIAG_SELF_EXCLUDE */
       con_id,
       sql_id,
       child_number,
       parsing_schema_name,
       executions,
       ROUND(elapsed_time / 1e6, 2) AS total_elapsed_sec,
       ROUND((elapsed_time / 1000) / NULLIF(executions, 0), 2) AS avg_elapsed_ms,
       buffer_gets,
       ROUND(buffer_gets / NULLIF(executions, 0), 1) AS buffer_gets_per_exec,
       disk_reads,
       rows_processed,
       SUBSTR(REPLACE(REPLACE(sql_text, CHR(10), ' '), CHR(13), ' '), 1, 72) AS sql_text_preview
  FROM v$sql
 WHERE con_id = TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'))
   AND parsing_schema_name NOT IN ('SYS', 'SYSMAN', 'SYSTEM', 'DBSNMP', 'AUDSYS', 'OUTLN', 'XDB', 'WMSYS')
   AND sql_text NOT LIKE '%/* DIAG_SELF_EXCLUDE */%'
 ORDER BY elapsed_time DESC, buffer_gets DESC
 FETCH FIRST 15 ROWS ONLY;

-- ============================================================================
-- QUERY 2: Active Non-Idle Wait Events Profile (V$SYSTEM_EVENT)
--          Highlights CPU/IO/Concurrency/Application bottlenecks since startup
-- ============================================================================
PROMPT ========================================================================
PROMPT [2/4] NON-IDLE WAIT EVENTS PROFILE (V$SYSTEM_EVENT, % OF DB WAIT TIME)
PROMPT ========================================================================
SELECT con_id,
       wait_class,
       event,
       total_waits,
       total_timeouts,
       ROUND(time_waited_micro / 1e6, 2) AS time_waited_sec,
       ROUND((time_waited_micro / 1000) / NULLIF(total_waits, 0), 2) AS avg_wait_ms,
       ROUND(
         100 * time_waited_micro / NULLIF(SUM(time_waited_micro) OVER (), 0),
         2
       ) AS pct_db_wait_time
  FROM v$system_event
 WHERE con_id = TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'))
   AND wait_class <> 'Idle'
   AND total_waits > 0
 ORDER BY time_waited_micro DESC
 FETCH FIRST 20 ROWS ONLY;

-- ============================================================================
-- QUERY 3: Shared Pool Hard-Parse / Literal-SQL Pressure Detector (V$SQL)
--          Catches bind-variable starvation (>5 distinct SQL_IDs sharing the
--          same force_matching_signature) before ORA-04031 or mutex storms hit
-- ============================================================================
PROMPT ========================================================================
PROMPT [3/4] SHARED POOL LITERAL-SQL / HARD-PARSE DETECTOR (FORCE_MATCHING_SIGNATURE)
PROMPT ========================================================================
SELECT /* DIAG_SELF_EXCLUDE */
       con_id,
       TO_CHAR(force_matching_signature) AS force_matching_sig,
       COUNT(*) AS cursor_cnt,
       COUNT(DISTINCT sql_id) AS distinct_sql_id_cnt,
       SUM(executions) AS total_executions,
       SUM(parse_calls) AS total_parse_calls,
       ROUND(SUM(sharable_mem) / 1024 / 1024, 2) AS shared_pool_mb,
       MIN(parsing_schema_name) AS sample_schema,
       MIN(sql_id) AS sample_sql_id,
       SUBSTR(REPLACE(REPLACE(MIN(sql_text), CHR(10), ' '), CHR(13), ' '), 1, 68) AS sample_sql_text
  FROM v$sql
 WHERE con_id = TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'))
   AND force_matching_signature > 0
   AND parsing_schema_name NOT IN ('SYS', 'SYSMAN')
   AND sql_text NOT LIKE '%/* DIAG_SELF_EXCLUDE */%'
 GROUP BY con_id, force_matching_signature
HAVING COUNT(*) > 5
   AND COUNT(DISTINCT sql_id) > 5
 ORDER BY distinct_sql_id_cnt DESC, shared_pool_mb DESC
 FETCH FIRST 15 ROWS ONLY;

-- ============================================================================
-- QUERY 4: PGA & SGA Memory Advisory Snapshot
--          Watch for PGA 'over allocation count' > 0 or high SGA oper_count
--          (indicates ASMM Shared Pool <-> Buffer Cache resize thrashing)
-- ============================================================================
PROMPT ========================================================================
PROMPT [4A/4] PGA MEMORY UTILIZATION & OVER-ALLOCATION SNAPSHOT (V$PGASTAT)
PROMPT ========================================================================
SELECT con_id,
       name,
       CASE
         WHEN unit = 'bytes' THEN ROUND(value / 1024 / 1024, 2)
         ELSE value
       END AS metric_value,
       CASE
         WHEN unit = 'bytes' THEN 'MB'
         ELSE NVL(unit, 'count')
       END AS metric_unit
  FROM v$pgastat
 WHERE con_id IN (0, TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID')))
 ORDER BY con_id, name;

PROMPT ========================================================================
PROMPT [4B/4] SGA DYNAMIC COMPONENTS & ASMM RESIZE HISTORY (V$SGA_DYNAMIC_COMPONENTS)
PROMPT ========================================================================
SELECT con_id,
       component,
       ROUND(current_size / 1024 / 1024, 1) AS current_mb,
       ROUND(min_size / 1024 / 1024, 1) AS min_mb,
       ROUND(max_size / 1024 / 1024, 1) AS max_mb,
       ROUND(user_specified_size / 1024 / 1024, 1) AS user_spec_mb,
       oper_count,
       last_oper_type,
       TO_CHAR(last_oper_time, 'YYYY-MM-DD HH24:MI:SS') AS last_oper_time
  FROM v$sga_dynamic_components
 WHERE con_id IN (0, TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID')))
   AND (current_size > 0 OR oper_count > 0)
 ORDER BY current_size DESC, component;
