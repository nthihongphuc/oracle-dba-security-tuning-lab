-- ============================================================================
-- File:        04-diagnostics/02_blocking_tree_and_locks.sql
-- Purpose:     Oracle 19c/23ai Day-2 Incident Triage — Hierarchical Blocking
--              Session Tree, Locked Objects & Human-Readable Lock Modes, and
--              Long-Running Active Transactions / Undo Consumption (CON_ID-Aware).
-- Safety:      STRICTLY READ-ONLY (SELECT queries only; zero DDL/DML changes).
-- Execution:   Run as SYSDBA or a DBA diagnostic account with SELECT_CATALOG_ROLE:
--                sqlplus / as sysdba @/opt/lab/04-diagnostics/02_blocking_tree_and_locks.sql
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

COLUMN lock_level         FORMAT 999     HEADING 'LEVEL'
COLUMN blocking_hierarchy FORMAT A24
COLUMN con_id             FORMAT 999
COLUMN sid                FORMAT 99999
COLUMN serial#            FORMAT 999999
COLUMN username           FORMAT A16
COLUMN program            FORMAT A26     TRUNC
COLUMN status             FORMAT A10
COLUMN event              FORMAT A34     TRUNC
COLUMN seconds_in_wait    FORMAT 999,990 HEADING 'WAIT_SEC'
COLUMN blocking_session   FORMAT 99999   HEADING 'BLK_SID'
COLUMN sql_id             FORMAT A13
COLUMN prev_sql_id        FORMAT A13
COLUMN sql_text_preview   FORMAT A56     TRUNC
COLUMN owner              FORMAT A16
COLUMN object_name        FORMAT A28
COLUMN object_type        FORMAT A14
COLUMN lock_mode_code     FORMAT 99      HEADING 'MODE#'
COLUMN lock_mode_name     FORMAT A6      HEADING 'MODE'
COLUMN xid                FORMAT A18
COLUMN tx_status          FORMAT A10
COLUMN start_time         FORMAT A20
COLUMN elapsed_min        FORMAT 999,990.00
COLUMN used_ublk          FORMAT 999,999,990
COLUMN used_urec          FORMAT 999,999,990
COLUMN undo_mb            FORMAT 999,990.00

-- ============================================================================
-- QUERY 1: Hierarchical Blocking Session Tree (V$SESSION + V$SQL)
--          Starts at root blockers (blocking_session IS NULL) who actively
--          block >= 1 waiter; uses CONNECT BY NOCYCLE + CON_ID-safe V$SQL join
--          (address + hash/sql_id + child_number + con_id prevents fan-out).
-- ============================================================================
PROMPT ========================================================================
PROMPT [1/3] HIERARCHICAL BLOCKING SESSION TREE (CONNECT BY NOCYCLE, CON_ID-AWARE)
PROMPT ========================================================================
WITH sess_scope AS (
  SELECT con_id,
         sid,
         serial#,
         NVL(username, 'BACKGROUND') AS username,
         program,
         status,
         event,
         seconds_in_wait,
         blocking_session,
         sql_id,
         sql_child_number,
         sql_address,
         prev_sql_id
    FROM v$session
   WHERE con_id = TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'))
),
blocking_tree AS (
  SELECT ROWNUM AS tree_order,
         LEVEL AS lock_level,
         LPAD(' ', (LEVEL - 1) * 3, ' ') ||
         CASE WHEN LEVEL = 1 THEN '[ROOT] ' ELSE '|-- ' END ||
         TO_CHAR(sid) AS blocking_hierarchy,
         con_id,
         sid,
         serial#,
         username,
         program,
         status,
         event,
         seconds_in_wait,
         blocking_session,
         sql_id,
         sql_child_number,
         sql_address,
         prev_sql_id
    FROM sess_scope
   START WITH blocking_session IS NULL
     AND sid IN (
           SELECT DISTINCT blocking_session
             FROM sess_scope
            WHERE blocking_session IS NOT NULL
         )
 CONNECT BY NOCYCLE PRIOR sid = blocking_session
     AND PRIOR con_id = con_id
)
SELECT bt.lock_level,
       bt.blocking_hierarchy,
       bt.con_id,
       bt.sid,
       bt.serial#,
       bt.username,
       bt.program,
       bt.status,
       bt.event,
       bt.seconds_in_wait,
       bt.blocking_session,
       bt.sql_id,
       bt.prev_sql_id,
       SUBSTR(REPLACE(REPLACE(q.sql_text, CHR(10), ' '), CHR(13), ' '), 1, 56) AS sql_text_preview
  FROM blocking_tree bt
  LEFT JOIN v$sql q
    ON q.sql_id       = bt.sql_id
   AND q.child_number = bt.sql_child_number
   AND q.address      = bt.sql_address
   AND q.con_id       = bt.con_id
 ORDER BY bt.tree_order;

-- ============================================================================
-- QUERY 2: Locked Objects & Human-Readable TM/TX Lock Modes
--          Decodes v$locked_object.locked_mode (0..6):
--            0=NONE, 1=NULL, 2=RS, 3=RX, 4=S (watch for unindexed FK!),
--            5=SRX, 6=X (exclusive table lock)
-- ============================================================================
PROMPT ========================================================================
PROMPT [2/3] LOCKED OBJECTS & LOCK MODES (V$LOCKED_OBJECT + DBA_OBJECTS)
PROMPT ========================================================================
SELECT lo.con_id,
       s.sid,
       s.serial#,
       s.username,
       s.status,
       s.blocking_session,
       o.owner,
       o.object_name,
       o.object_type,
       lo.locked_mode AS lock_mode_code,
       CASE lo.locked_mode
         WHEN 0 THEN 'NONE'
         WHEN 1 THEN 'NULL'
         WHEN 2 THEN 'RS'
         WHEN 3 THEN 'RX'
         WHEN 4 THEN 'S'
         WHEN 5 THEN 'SRX'
         WHEN 6 THEN 'X'
         ELSE TO_CHAR(lo.locked_mode)
       END AS lock_mode_name,
       s.event,
       s.seconds_in_wait
  FROM v$locked_object lo
  JOIN dba_objects o
    ON o.object_id = lo.object_id
  JOIN v$session s
    ON s.sid    = lo.session_id
   AND s.con_id = lo.con_id
 WHERE lo.con_id = TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'))
 ORDER BY lo.locked_mode DESC, s.seconds_in_wait DESC, o.owner, o.object_name;

-- ============================================================================
-- QUERY 3: Long-Running Active Transactions & Undo Consumption (V$TRANSACTION)
--          Pinpoints uncommitted DML holding row locks, driving UNDO bloat, or
--          risking ORA-01555 (snapshot too old) / ORA-30036 (undo exhaustion)
-- ============================================================================
PROMPT ========================================================================
PROMPT [3/3] ACTIVE TRANSACTIONS & UNDO CONSUMPTION (V$TRANSACTION + V$SESSION)
PROMPT ========================================================================
SELECT t.con_id,
       s.sid,
       s.serial#,
       s.username,
       s.status,
       s.program,
       t.xidusn || '.' || t.xidslot || '.' || t.xidsqn AS xid,
       t.status AS tx_status,
       t.start_time,
       ROUND((SYSDATE - t.start_date) * 1440, 2) AS elapsed_min,
       t.used_ublk,
       t.used_urec,
       ROUND(t.used_ublk * p.db_block_size / 1024 / 1024, 2) AS undo_mb,
       t.log_io,
       t.phy_io,
       COALESCE(s.sql_id, s.prev_sql_id) AS sql_id
  FROM v$transaction t
  JOIN v$session s
    ON s.taddr  = t.addr
   AND s.con_id = t.con_id
 CROSS JOIN (
         SELECT TO_NUMBER(value) AS db_block_size
           FROM v$parameter
          WHERE name = 'db_block_size'
       ) p
 WHERE t.con_id = TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'))
 ORDER BY t.used_ublk DESC, t.start_date ASC;
