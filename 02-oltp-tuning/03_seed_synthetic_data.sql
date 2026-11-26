-- ============================================================================
-- File:        02-oltp-tuning/03_seed_synthetic_data.sql
-- Purpose:     High-Speed Synthetic Data Generator (~801,000 OLTP Rows)
--              Uses memory-safe Cross-Join Cartesian row generators (max
--              CONNECT BY depth <= 1,000) to guarantee ZERO ORA-30009 errors
--              under Oracle 23ai Free's 2 GB RAM cap, deterministic DBMS_RANDOM
--              seeding, and DBMS_STATS.GATHER_SCHEMA_STATS.
-- Execution:   Run in FREEPDB1 connected as HOTEL_APP (or SYSDBA).
-- ============================================================================

WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET SERVEROUTPUT ON
SET TIMING ON

ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = hotel_app;

-- Deterministic seed for repeatable benchmark plans & cardinalities
BEGIN
  DBMS_RANDOM.SEED(42);
END;
/

PROMPT === 1/7 Seeding room_types (8 rows) ===
INSERT INTO hotel_app.room_types (type_code, type_name, base_nightly_rate, max_occupancy)
SELECT 'STD_TWIN',  'Standard Twin',       95.00,  2 FROM dual UNION ALL
SELECT 'STD_KING',  'Standard King',      110.00,  2 FROM dual UNION ALL
SELECT 'DLX_KING',  'Deluxe King',        165.00,  3 FROM dual UNION ALL
SELECT 'DLX_VIEW',  'Deluxe Ocean View',  210.00,  3 FROM dual UNION ALL
SELECT 'EXEC_STE',  'Executive Suite',    320.00,  4 FROM dual UNION ALL
SELECT 'FAM_STE',   'Family Suite',       285.00,  5 FROM dual UNION ALL
SELECT 'PENT_JR',   'Junior Penthouse',   540.00,  4 FROM dual UNION ALL
SELECT 'PENT_ROY',  'Royal Penthouse',    980.00,  6 FROM dual;
COMMIT;

PROMPT === 2/7 Seeding rooms (1,000 rows) ===
-- Note: Direct-path /*+ APPEND */ is ignored by Oracle on child tables with enabled FKs;
--       pure set-based INSERT keeps undo/redo compact while enforcing FK integrity.
INSERT INTO hotel_app.rooms (room_number, room_type_id, floor_number, status, is_active)
SELECT 'RM-' || LPAD(lvl, 4, '0'),
       MOD(lvl - 1, 8) + 1,
       TRUNC((lvl - 1) / 50) + 1,
       CASE WHEN MOD(lvl, 50) = 0 THEN 'MAINTENANCE' ELSE 'AVAILABLE' END,
       'Y'
  FROM (SELECT LEVEL AS lvl FROM dual CONNECT BY LEVEL <= 1000);
COMMIT;

PROMPT === 3/7 Seeding customers (50,000 rows via 500 x 100 cross-join generator) ===
-- customers has no outbound FK constraints, so direct-path /*+ APPEND */ applies cleanly.
INSERT /*+ APPEND */ INTO hotel_app.customers (email, full_name, phone_number, loyalty_tier)
WITH g1 AS (SELECT /*+ MATERIALIZE */ LEVEL AS n FROM dual CONNECT BY LEVEL <= 500),
     g2 AS (SELECT /*+ MATERIALIZE */ LEVEL AS m FROM dual CONNECT BY LEVEL <= 100),
     gen AS (SELECT (g1.n - 1) * 100 + g2.m AS lvl FROM g1 CROSS JOIN g2)
SELECT 'guest' || lvl || '@synthetic-hotel.example',
       'Guest User ' || lvl,
       '+1-555-' || LPAD(MOD(lvl * 37, 9999999), 7, '0'),
       CASE MOD(lvl, 10)
         WHEN 0 THEN 'PLATINUM'
         WHEN 1 THEN 'GOLD'
         WHEN 2 THEN 'GOLD'
         WHEN 3 THEN 'SILVER'
         WHEN 4 THEN 'SILVER'
         ELSE 'STANDARD'
       END
  FROM gen;
COMMIT;

PROMPT === 4/7 Seeding services (15 rows) ===
INSERT INTO hotel_app.services (service_code, service_name, unit_price, is_active)
SELECT 'SVC-' || LPAD(lvl, 2, '0'),
       'Hotel Service ' || lvl,
       ROUND(15 + (lvl * 12.5), 2),
       'Y'
  FROM (SELECT LEVEL AS lvl FROM dual CONNECT BY LEVEL <= 15);
COMMIT;

PROMPT === 5/7 Seeding bookings (250,000 rows via 1,000 x 250 cross-join generator) ===
-- Cross-join avoids single-level CONNECT BY <= 250000 which causes ORA-30009 under 2 GB RAM!
INSERT INTO hotel_app.bookings (booking_ref, customer_id, check_in_date, check_out_date, booking_status)
WITH g1 AS (SELECT /*+ MATERIALIZE */ LEVEL AS n FROM dual CONNECT BY LEVEL <= 1000),
     g2 AS (SELECT /*+ MATERIALIZE */ LEVEL AS m FROM dual CONNECT BY LEVEL <= 250),
     gen AS (
       SELECT (g1.n - 1) * 250 + g2.m AS lvl
         FROM g1
        CROSS JOIN g2
     ),
     dated AS (
       SELECT lvl,
              TRUNC(DATE '2024-01-01' + MOD(lvl * 13, 1095)) AS dt_in,
              MOD(lvl, 6) + 1 AS nights
         FROM gen
     )
SELECT 'BK-SEED-' || LPAD(lvl, 8, '0'),
       TRUNC(DBMS_RANDOM.VALUE(1, 50001)),
       dt_in,
       dt_in + nights,
       CASE MOD(lvl, 10)
         WHEN 0 THEN 'CANCELLED'
         WHEN 1 THEN 'PENDING'
         WHEN 2 THEN 'CHECKED_IN'
         WHEN 3 THEN 'CONFIRMED'
         WHEN 4 THEN 'CONFIRMED'
         ELSE 'CHECKED_OUT'
       END
  FROM dated;
COMMIT;

PROMPT === 6/7 Seeding booking_rooms (250,000 rows) ===
INSERT INTO hotel_app.booking_rooms (booking_id, room_id, check_in_date, check_out_date, agreed_nightly_rate)
SELECT b.booking_id,
       MOD(b.booking_id * 17, 1000) + 1,
       b.check_in_date,
       b.check_out_date,
       ROUND(95 + MOD(b.booking_id, 9) * 45.5, 2)
  FROM hotel_app.bookings b;
COMMIT;

PROMPT === 7/7 Seeding service_orders (250,000 rows via 1,000 x 250 cross-join generator) ===
INSERT INTO hotel_app.service_orders (booking_id, service_id, quantity, unit_price_snapshot)
WITH g1 AS (SELECT /*+ MATERIALIZE */ LEVEL AS n FROM dual CONNECT BY LEVEL <= 1000),
     g2 AS (SELECT /*+ MATERIALIZE */ LEVEL AS m FROM dual CONNECT BY LEVEL <= 250),
     gen AS (SELECT (g1.n - 1) * 250 + g2.m AS lvl FROM g1 CROSS JOIN g2)
SELECT MOD(lvl * 31, 250000) + 1,
       MOD(lvl, 15) + 1,
       MOD(lvl, 4) + 1,
       ROUND(15 + (MOD(lvl, 15) + 1) * 12.5, 2)
  FROM gen;
COMMIT;

PROMPT === Gathering Optimizer Statistics (DBMS_STATS) ===
BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS(
    ownname          => 'HOTEL_APP',
    estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
    method_opt       => 'FOR ALL COLUMNS SIZE AUTO',
    cascade          => TRUE,
    degree           => DBMS_STATS.AUTO_DEGREE
  );
END;
/

PROMPT === Dataset Volume & Segment Summary ===
SELECT table_name, num_rows, blocks, last_analyzed
  FROM all_tables
 WHERE owner = 'HOTEL_APP'
 ORDER BY num_rows DESC NULLS LAST;
