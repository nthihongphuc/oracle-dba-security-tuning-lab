-- ============================================================================
-- File:        02-oltp-tuning/04_benchmark_xplan.sql
-- Purpose:     Before vs After Execution Plan & Performance Benchmark Suite
--              Uses /*+ GATHER_PLAN_STATISTICS */ and DBMS_XPLAN.DISPLAY_CURSOR
--              with zero-downtime INVISIBLE / VISIBLE index toggling to prove:
--                Benchmark 1: Covering Composite Index (idx_br_room_dates)
--                Benchmark 2: Foreign Key Index (idx_bookings_customer_id)
--                Benchmark 3: Row-by-Row PL/SQL Loop vs Pure Set-Based SQL
-- Execution:   Run in FREEPDB1 connected as HOTEL_APP (after 03_seed_synthetic_data.sql).
-- ============================================================================

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET LINESIZE 220
SET PAGESIZE 120
SET TAB OFF
SET TRIMSPOOL ON
SET FEEDBACK ON

-- CRITICAL SQL*PLUS BEST PRACTICE:
--   SERVEROUTPUT MUST BE OFF when calling DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, ...).
--   With SERVEROUTPUT ON, SQL*Plus silently calls DBMS_OUTPUT.GET_LINES after every
--   SQL statement, overwriting PREV_SQL_ID and hiding the target query's plan!
SET SERVEROUTPUT OFF

ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = hotel_app;

-- ============================================================================
-- BENCHMARK 1: Room Availability Overlap Probe (250k booking_rooms rows)
--   BEFORE: idx_br_room_dates INVISIBLE -> Full Table Scan (high consistent gets)
--   AFTER:  idx_br_room_dates VISIBLE   -> Covering Index Range Scan (< 10 buffers)
-- ============================================================================
PROMPT ========================================================================
PROMPT [BENCHMARK 1 - BEFORE] idx_br_room_dates INVISIBLE (Missing Composite FK Index)
PROMPT ========================================================================
ALTER INDEX hotel_app.idx_br_room_dates INVISIBLE;

VAR b_room_id   NUMBER;
VAR b_check_in  VARCHAR2(10);
VAR b_check_out VARCHAR2(10);

BEGIN
  :b_room_id   := 425;
  :b_check_in  := '2026-06-10';
  :b_check_out := '2026-06-15';
END;
/

SELECT /*+ GATHER_PLAN_STATISTICS */ /* BM1_BEFORE */
       COUNT(*) AS overlap_cnt
  FROM hotel_app.booking_rooms br
  JOIN hotel_app.bookings b
    ON b.booking_id = br.booking_id
 WHERE br.room_id        = :b_room_id
   AND b.booking_status IN ('PENDING', 'CONFIRMED', 'CHECKED_IN')
   AND br.check_in_date  < TO_DATE(:b_check_out, 'YYYY-MM-DD')
   AND br.check_out_date > TO_DATE(:b_check_in,  'YYYY-MM-DD');

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST +COST +BYTES'));

PROMPT ========================================================================
PROMPT [BENCHMARK 1 - AFTER] idx_br_room_dates VISIBLE (Covering Composite Index Active)
PROMPT ========================================================================
ALTER INDEX hotel_app.idx_br_room_dates VISIBLE;

SELECT /*+ GATHER_PLAN_STATISTICS */ /* BM1_AFTER */
       COUNT(*) AS overlap_cnt
  FROM hotel_app.booking_rooms br
  JOIN hotel_app.bookings b
    ON b.booking_id = br.booking_id
 WHERE br.room_id        = :b_room_id
   AND b.booking_status IN ('PENDING', 'CONFIRMED', 'CHECKED_IN')
   AND br.check_in_date  < TO_DATE(:b_check_out, 'YYYY-MM-DD')
   AND br.check_out_date > TO_DATE(:b_check_in,  'YYYY-MM-DD');

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST +COST +BYTES'));

-- ============================================================================
-- BENCHMARK 2: Customer Booking History Lookup (250k bookings rows)
--   BEFORE: idx_bookings_customer_id INVISIBLE -> TABLE ACCESS FULL + SORT
--   AFTER:  idx_bookings_customer_id VISIBLE   -> INDEX RANGE SCAN (No Sort!)
-- ============================================================================
PROMPT ========================================================================
PROMPT [BENCHMARK 2 - BEFORE] idx_bookings_customer_id INVISIBLE (Unindexed FK)
PROMPT ========================================================================
ALTER INDEX hotel_app.idx_bookings_customer_id INVISIBLE;

VAR b_cust_id NUMBER;
BEGIN
  :b_cust_id := 12345;
END;
/

SELECT /*+ GATHER_PLAN_STATISTICS */ /* BM2_BEFORE */
       booking_id, booking_ref, check_in_date, check_out_date, booking_status
  FROM hotel_app.bookings
 WHERE customer_id = :b_cust_id
 ORDER BY check_in_date DESC;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST +COST +BYTES'));

PROMPT ========================================================================
PROMPT [BENCHMARK 2 - AFTER] idx_bookings_customer_id VISIBLE (Indexed FK + Pre-Sorted)
PROMPT ========================================================================
ALTER INDEX hotel_app.idx_bookings_customer_id VISIBLE;

SELECT /*+ GATHER_PLAN_STATISTICS */ /* BM2_AFTER */
       booking_id, booking_ref, check_in_date, check_out_date, booking_status
  FROM hotel_app.bookings
 WHERE customer_id = :b_cust_id
 ORDER BY check_in_date DESC;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST +COST +BYTES'));

-- ============================================================================
-- BENCHMARK 3: Row-by-Row PL/SQL Context-Switch Loop vs Pure Set-Based SQL
--   Computes total room + service revenue across 10,000 bookings (IDs 1..10000).
-- ============================================================================
PROMPT ========================================================================
PROMPT [BENCHMARK 3] Row-by-Row PL/SQL Loop vs Pure Set-Based SQL Aggregation
PROMPT ========================================================================
SET SERVEROUTPUT ON

DECLARE
  v_t0             PLS_INTEGER;
  v_t1             PLS_INTEGER;
  v_gets_before    NUMBER;
  v_gets_after     NUMBER;
  v_grand_total_r  NUMBER(16,2) := 0;
  v_grand_total_s  NUMBER(16,2) := 0;
  v_room_amt       NUMBER(12,2);
  v_svc_amt        NUMBER(12,2);

  FUNCTION get_session_logical_reads RETURN NUMBER IS
    v_val NUMBER;
  BEGIN
    SELECT m.value
      INTO v_val
      FROM v$mystat m
      JOIN v$statname s ON s.statistic# = m.statistic#
     WHERE s.name = 'session logical reads';
    RETURN v_val;
  END;
BEGIN
  -- BEFORE: Anti-pattern Row-by-Row Cursor Loop (20,000+ SQL-PL/SQL context switches)
  v_gets_before := get_session_logical_reads();
  v_t0          := DBMS_UTILITY.GET_TIME;

  FOR rec IN (SELECT booking_id FROM hotel_app.bookings WHERE booking_id <= 10000) LOOP
    SELECT NVL(SUM((check_out_date - check_in_date) * agreed_nightly_rate), 0)
      INTO v_room_amt
      FROM hotel_app.booking_rooms
     WHERE booking_id = rec.booking_id;

    SELECT NVL(SUM(quantity * unit_price_snapshot), 0)
      INTO v_svc_amt
      FROM hotel_app.service_orders
     WHERE booking_id = rec.booking_id;

    v_grand_total_r := v_grand_total_r + v_room_amt + v_svc_amt;
  END LOOP;

  v_t1         := DBMS_UTILITY.GET_TIME;
  v_gets_after := get_session_logical_reads();
  DBMS_OUTPUT.PUT_LINE(
    '[BEFORE - Row-by-Row Loop] Total=' || TO_CHAR(v_grand_total_r, '999,999,999.00') ||
    ' | Elapsed=' || TO_CHAR((v_t1 - v_t0) / 100, '0.00') || 's' ||
    ' | Logical Reads=' || (v_gets_after - v_gets_before)
  );

  -- AFTER: Pure Set-Based SQL Aggregation (1 single SQL engine execution)
  v_gets_before := get_session_logical_reads();
  v_t0          := DBMS_UTILITY.GET_TIME;

  WITH room_agg AS (
    SELECT booking_id, SUM((check_out_date - check_in_date) * agreed_nightly_rate) AS room_amt
      FROM hotel_app.booking_rooms
     WHERE booking_id <= 10000
     GROUP BY booking_id
  ),
  svc_agg AS (
    SELECT booking_id, SUM(quantity * unit_price_snapshot) AS svc_amt
      FROM hotel_app.service_orders
     WHERE booking_id <= 10000
     GROUP BY booking_id
  )
  SELECT NVL(SUM(NVL(r.room_amt, 0) + NVL(s.svc_amt, 0)), 0)
    INTO v_grand_total_s
    FROM hotel_app.bookings b
    LEFT JOIN room_agg r ON r.booking_id = b.booking_id
    LEFT JOIN svc_agg  s ON s.booking_id = b.booking_id
   WHERE b.booking_id <= 10000;

  v_t1         := DBMS_UTILITY.GET_TIME;
  v_gets_after := get_session_logical_reads();
  DBMS_OUTPUT.PUT_LINE(
    '[AFTER  - Set-Based SQL  ] Total=' || TO_CHAR(v_grand_total_s, '999,999,999.00') ||
    ' | Elapsed=' || TO_CHAR((v_t1 - v_t0) / 100, '0.00') || 's' ||
    ' | Logical Reads=' || (v_gets_after - v_gets_before)
  );

  IF v_grand_total_r <> v_grand_total_s THEN
    RAISE_APPLICATION_ERROR(
      -20401,
      'Benchmark mismatch: row-by-row=' || v_grand_total_r || ' vs set-based=' || v_grand_total_s
    );
  END IF;
END;
/

-- Turn SERVEROUTPUT back OFF so DISPLAY_CURSOR captures the Set-Based SQL plan accurately
SET SERVEROUTPUT OFF

-- Capture execution plan for the Set-Based Aggregation query
WITH room_agg AS (
  SELECT booking_id, SUM((check_out_date - check_in_date) * agreed_nightly_rate) AS room_amt
    FROM hotel_app.booking_rooms
   WHERE booking_id <= 10000
   GROUP BY booking_id
),
svc_agg AS (
  SELECT booking_id, SUM(quantity * unit_price_snapshot) AS svc_amt
    FROM hotel_app.service_orders
   WHERE booking_id <= 10000
   GROUP BY booking_id
)
SELECT /*+ GATHER_PLAN_STATISTICS */ /* BM3_SET_BASED */
       NVL(SUM(NVL(r.room_amt, 0) + NVL(s.svc_amt, 0)), 0) AS grand_total
  FROM hotel_app.bookings b
  LEFT JOIN room_agg r ON r.booking_id = b.booking_id
  LEFT JOIN svc_agg  s ON s.booking_id = b.booking_id
 WHERE b.booking_id <= 10000;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST +COST +BYTES'));
