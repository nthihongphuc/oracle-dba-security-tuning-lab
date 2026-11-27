-- ============================================================================
-- File:        04-diagnostics/04_invalid_objects_stale_stats.sql
-- Purpose:     Oracle 19c/23ai Day-2 Schema Hygiene & Optimizer Health Audit —
--              Invalid Application Objects (+ DBMS_UTILITY.COMPILE_SCHEMA
--              advisory), Stale/Missing Table Statistics, Unindexed Foreign
--              Keys, Unusable Indexes/Partitions, and Top 15 Largest Segments.
-- Safety:      STRICTLY READ-ONLY (SELECT queries only; zero DDL/DML changes).
--              Remediation commands are emitted as text advisories for DBA
--              change-control review rather than executed automatically.
-- Execution:   Run as SYSDBA or a DBA diagnostic account with SELECT_CATALOG_ROLE:
--                sqlplus / as sysdba @/opt/lab/04-diagnostics/04_invalid_objects_stale_stats.sql
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

COLUMN owner              FORMAT A14
COLUMN object_type        FORMAT A20
COLUMN object_name        FORMAT A30
COLUMN status             FORMAT A10
COLUMN last_ddl_time      FORMAT A19
COLUMN recompile_advisory FORMAT A78
COLUMN table_name         FORMAT A28
COLUMN partition_name     FORMAT A24
COLUMN last_analyzed      FORMAT A19
COLUMN stale_stats        FORMAT A10
COLUMN stats_locked       FORMAT A10
COLUMN stats_advisory     FORMAT A92
COLUMN constraint_name    FORMAT A30
COLUMN fk_columns         FORMAT A36
COLUMN finding            FORMAT A38
COLUMN index_name         FORMAT A30
COLUMN tablespace_name    FORMAT A20
COLUMN segment_name       FORMAT A30
COLUMN segment_type       FORMAT A18
COLUMN size_mb            FORMAT 999,990.00
COLUMN pct_app_storage    FORMAT 990.00 HEADING 'PCT_APP'

-- ============================================================================
-- QUERY 1: Invalid Schema Objects + Ready-to-Review Recompile Advisory
--          Targets application schemas HOTEL_APP and SEC_ADMIN
-- ============================================================================
PROMPT ========================================================================
PROMPT [1A/4] INVALID APPLICATION OBJECTS (DBA_OBJECTS: HOTEL_APP, SEC_ADMIN)
PROMPT ========================================================================
SELECT owner,
       object_type,
       object_name,
       status,
       TO_CHAR(last_ddl_time, 'YYYY-MM-DD HH24:MI:SS') AS last_ddl_time
  FROM dba_objects
 WHERE owner IN ('HOTEL_APP', 'SEC_ADMIN')
   AND status <> 'VALID'
 ORDER BY owner, object_type, object_name;

PROMPT ========================================================================
PROMPT [1B/4] RECOMPILE ADVISORY (REVIEW BEFORE RUNNING — READ-ONLY OUTPUT)
PROMPT ========================================================================
SELECT owner,
       COUNT(*) AS invalid_object_cnt,
       'EXEC DBMS_UTILITY.COMPILE_SCHEMA(schema => ''' || owner || ''', compile_all => FALSE);' AS recompile_advisory
  FROM dba_objects
 WHERE owner IN ('HOTEL_APP', 'SEC_ADMIN')
   AND status <> 'VALID'
 GROUP BY owner
 ORDER BY owner;

-- ============================================================================
-- QUERY 2: Stale or Missing Optimizer Statistics (DBA_TAB_STATISTICS)
--          Prevents severe CBO cardinality misestimates & plan regressions
-- ============================================================================
PROMPT ========================================================================
PROMPT [2/4] STALE OR MISSING OPTIMIZER STATISTICS (DBA_TAB_STATISTICS)
PROMPT ========================================================================
SELECT owner,
       table_name,
       NVL(partition_name, '-') AS partition_name,
       object_type,
       num_rows,
       blocks,
       TO_CHAR(last_analyzed, 'YYYY-MM-DD HH24:MI:SS') AS last_analyzed,
       NVL(stale_stats, 'MISSING') AS stale_stats,
       NVL(stattype_locked, 'NONE') AS stats_locked,
       'EXEC DBMS_STATS.GATHER_TABLE_STATS(ownname => ''' || owner || ''', tabname => ''' || table_name || ''', degree => DBMS_STATS.AUTO_DEGREE);' AS stats_advisory
  FROM dba_tab_statistics
 WHERE owner IN ('HOTEL_APP', 'SEC_ADMIN')
   AND (stale_stats = 'YES' OR last_analyzed IS NULL)
 ORDER BY owner, stale_stats DESC NULLS FIRST, num_rows DESC NULLS LAST, table_name;

-- ============================================================================
-- QUERY 3: Unindexed Foreign Key Audit & Unusable Index / Partition Check
--          3A catches child-table FKs lacking a usable leading-column index
--             (which causes TM table locks during parent row changes & FTS).
--          3B catches UNUSABLE indexes & index partitions (causes ORA-01502).
-- ============================================================================
PROMPT ========================================================================
PROMPT [3A/4] UNINDEXED FOREIGN KEY AUDIT (HOTEL_APP, SEC_ADMIN)
PROMPT ========================================================================
WITH fk_cols AS (
  SELECT c.owner,
         c.table_name,
         c.constraint_name,
         LISTAGG(cc.column_name, ',') WITHIN GROUP (ORDER BY cc.position) AS fk_columns
    FROM dba_constraints c
    JOIN dba_cons_columns cc
      ON cc.owner           = c.owner
     AND cc.constraint_name = c.constraint_name
     AND cc.table_name      = c.table_name
   WHERE c.owner IN ('HOTEL_APP', 'SEC_ADMIN')
     AND c.constraint_type = 'R'
   GROUP BY c.owner, c.table_name, c.constraint_name
),
usable_idx_cols AS (
  SELECT i.table_owner,
         i.table_name,
         i.index_name,
         LISTAGG(ic.column_name, ',') WITHIN GROUP (ORDER BY ic.column_position) AS idx_columns
    FROM dba_indexes i
    JOIN dba_ind_columns ic
      ON ic.index_owner = i.owner
     AND ic.index_name  = i.index_name
     AND ic.table_owner = i.table_owner
     AND ic.table_name  = i.table_name
   WHERE i.table_owner IN ('HOTEL_APP', 'SEC_ADMIN')
     AND i.status <> 'UNUSABLE'
   GROUP BY i.table_owner, i.table_name, i.index_name
)
SELECT fk.owner,
       fk.table_name,
       fk.constraint_name,
       fk.fk_columns,
       'UNINDEXED_FK (TM Lock & FTS Risk)' AS finding
  FROM fk_cols fk
 WHERE NOT EXISTS (
         SELECT 1
           FROM usable_idx_cols ix
          WHERE ix.table_owner = fk.owner
            AND ix.table_name  = fk.table_name
            AND (
                  ix.idx_columns = fk.fk_columns
               OR ix.idx_columns LIKE fk.fk_columns || ',%'
                )
       )
 ORDER BY fk.owner, fk.table_name, fk.constraint_name;

PROMPT ========================================================================
PROMPT [3B/4] UNUSABLE INDEXES & INDEX PARTITIONS (DBA_INDEXES + DBA_IND_PARTITIONS)
PROMPT ========================================================================
SELECT owner,
       index_name,
       table_name,
       'NON-PARTITIONED' AS partition_name,
       tablespace_name,
       status
  FROM dba_indexes
 WHERE owner IN ('HOTEL_APP', 'SEC_ADMIN')
   AND status = 'UNUSABLE'
UNION ALL
SELECT p.index_owner AS owner,
       p.index_name,
       i.table_name,
       p.partition_name,
       p.tablespace_name,
       p.status
  FROM dba_ind_partitions p
  JOIN dba_indexes i
    ON i.owner      = p.index_owner
   AND i.index_name = p.index_name
 WHERE p.index_owner IN ('HOTEL_APP', 'SEC_ADMIN')
   AND p.status = 'UNUSABLE'
 ORDER BY 1, 2, 4;

-- ============================================================================
-- QUERY 4: High-Watermark / Top 15 Largest Application Segments (DBA_SEGMENTS)
-- ============================================================================
PROMPT ========================================================================
PROMPT [4/4] TOP 15 LARGEST SEGMENTS / HIGH-WATERMARK FOOTPRINT (DBA_SEGMENTS)
PROMPT ========================================================================
SELECT owner,
       segment_name,
       NVL(partition_name, '-') AS partition_name,
       segment_type,
       tablespace_name,
       extents,
       blocks,
       ROUND(bytes / 1024 / 1024, 2) AS size_mb,
       ROUND(100 * bytes / NULLIF(SUM(bytes) OVER (), 0), 2) AS pct_app_storage
  FROM dba_segments
 WHERE owner IN ('HOTEL_APP', 'SEC_ADMIN')
 ORDER BY bytes DESC
 FETCH FIRST 15 ROWS ONLY;
