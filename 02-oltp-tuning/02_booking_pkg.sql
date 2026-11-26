-- ============================================================================
-- File:        02-oltp-tuning/02_booking_pkg.sql
-- Purpose:     Concurrency-Safe Hotel Booking & Set-Based Billing PL/SQL API
--              Fixes classic OLTP anti-patterns:
--                1. Replaces race-prone "ORDER BY id DESC FETCH FIRST 1" with
--                   atomic INSERT ... RETURNING booking_id INTO o_booking_id.
--                2. Serializes concurrent single- & multi-room reservations via
--                   deterministic ascending room_id lock ordering + pessimistic
--                   row-level lock: SELECT ... FOR UPDATE OF r.room_id WAIT 5
--                   (eliminates phantom double-bookings AND ORA-00060 deadlocks).
--                3. Explicitly handles ORA-30006 (WAIT timeout) across all
--                   locking entry points as retryable domain error -20305.
--                4. Computes multi-room / multi-night + ancillary service
--                   invoice totals via pure set-based SQL + idempotent MERGE.
-- Execution:   Run in FREEPDB1 connected as HOTEL_APP (or SYSDBA).
-- ============================================================================

WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET SERVEROUTPUT ON

ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = hotel_app;

-- Sequence for human-readable unique booking references
CREATE SEQUENCE hotel_app.seq_booking_ref
  START WITH 1000001
  INCREMENT BY 1
  CACHE 100
  NOORDER;

CREATE OR REPLACE PACKAGE hotel_app.pkg_hotel_booking
  AUTHID DEFINER
AS
  -- Collection type for atomic multi-room reservations
  TYPE t_room_id_tab IS TABLE OF hotel_app.rooms.room_id%TYPE;

  -- Domain-specific exceptions
  e_invalid_date_range  EXCEPTION;
  e_room_not_available  EXCEPTION;
  e_booking_not_found   EXCEPTION;
  e_invalid_state       EXCEPTION;
  e_resource_busy       EXCEPTION;
  e_lock_timeout        EXCEPTION;

  PRAGMA EXCEPTION_INIT(e_invalid_date_range, -20301);
  PRAGMA EXCEPTION_INIT(e_room_not_available, -20302);
  PRAGMA EXCEPTION_INIT(e_booking_not_found,  -20303);
  PRAGMA EXCEPTION_INIT(e_invalid_state,      -20304);
  PRAGMA EXCEPTION_INIT(e_resource_busy,      -20305); -- Retryable lock contention
  PRAGMA EXCEPTION_INIT(e_lock_timeout,       -30006); -- ORA-30006: FOR UPDATE WAIT timeout

  -- Creates a multi-room reservation safely under concurrent load using
  -- strictly ascending room_id lock ordering (caller controls COMMIT/ROLLBACK)
  PROCEDURE create_multi_room_booking (
    p_customer_id    IN  hotel_app.customers.customer_id%TYPE,
    p_room_ids       IN  t_room_id_tab,
    p_check_in_date  IN  DATE,
    p_check_out_date IN  DATE,
    o_booking_id     OUT hotel_app.bookings.booking_id%TYPE,
    o_booking_ref    OUT hotel_app.bookings.booking_ref%TYPE
  );

  -- Convenience wrapper for single-room reservations
  PROCEDURE create_booking (
    p_customer_id    IN  hotel_app.customers.customer_id%TYPE,
    p_room_id        IN  hotel_app.rooms.room_id%TYPE,
    p_check_in_date  IN  DATE,
    p_check_out_date IN  DATE,
    o_booking_id     OUT hotel_app.bookings.booking_id%TYPE,
    o_booking_ref    OUT hotel_app.bookings.booking_ref%TYPE
  );

  -- Appends an ancillary service order with unit price snapshotted at order time
  PROCEDURE add_service_order (
    p_booking_id       IN  hotel_app.bookings.booking_id%TYPE,
    p_service_id       IN  hotel_app.services.service_id%TYPE,
    p_quantity         IN  hotel_app.service_orders.quantity%TYPE,
    o_service_order_id OUT hotel_app.service_orders.service_order_id%TYPE
  );

  -- Pure set-based multi-room / multi-night invoice calculation & idempotent MERGE
  PROCEDURE calculate_invoice_total (
    p_booking_id   IN  hotel_app.bookings.booking_id%TYPE,
    p_tax_rate     IN  NUMBER DEFAULT 0.10,
    o_invoice_id   OUT hotel_app.invoices.invoice_id%TYPE,
    o_total_amount OUT hotel_app.invoices.total_amount%TYPE
  );

  -- Cancels an active booking safely using row-level lock and voids open invoices
  PROCEDURE cancel_booking (
    p_booking_id IN hotel_app.bookings.booking_id%TYPE
  );
END pkg_hotel_booking;
/
SHOW ERRORS PACKAGE hotel_app.pkg_hotel_booking

CREATE OR REPLACE PACKAGE BODY hotel_app.pkg_hotel_booking
AS

  PROCEDURE create_multi_room_booking (
    p_customer_id    IN  hotel_app.customers.customer_id%TYPE,
    p_room_ids       IN  t_room_id_tab,
    p_check_in_date  IN  DATE,
    p_check_out_date IN  DATE,
    o_booking_id     OUT hotel_app.bookings.booking_id%TYPE,
    o_booking_ref    OUT hotel_app.bookings.booking_ref%TYPE
  ) IS
    -- Associative array keyed by PLS_INTEGER keeps room_ids strictly sorted ASC
    -- so all concurrent sessions acquire row locks in deterministic order
    -- (eliminates circular-wait ORA-00060 deadlocks on multi-room bookings).
    TYPE t_room_rate_map IS TABLE OF hotel_app.room_types.base_nightly_rate%TYPE
      INDEX BY PLS_INTEGER;

    v_room_rates      t_room_rate_map;
    v_raw_rid         hotel_app.rooms.room_id%TYPE;
    v_rid             PLS_INTEGER;
    v_check_in        DATE := TRUNC(p_check_in_date);
    v_check_out       DATE := TRUNC(p_check_out_date);
    v_room_status     hotel_app.rooms.status%TYPE;
    v_nightly_rate    hotel_app.room_types.base_nightly_rate%TYPE;
    v_overlap_count   PLS_INTEGER;
    v_booking_room_id hotel_app.booking_rooms.booking_room_id%TYPE;
  BEGIN
    IF p_customer_id IS NULL THEN
      RAISE_APPLICATION_ERROR(-20304, 'customer_id is required.');
    END IF;

    IF v_check_in IS NULL OR v_check_out IS NULL OR v_check_out <= v_check_in THEN
      RAISE_APPLICATION_ERROR(-20301, 'check_out_date must be strictly later than check_in_date.');
    END IF;

    IF p_room_ids IS NULL OR p_room_ids.COUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20304, 'At least one room_id must be provided.');
    END IF;

    -- 1. Validate, reject duplicates, and sort room_ids strictly ascending
    FOR i IN p_room_ids.FIRST .. p_room_ids.LAST LOOP
      IF NOT p_room_ids.EXISTS(i) THEN
        CONTINUE;
      END IF;

      v_raw_rid := p_room_ids(i);
      IF v_raw_rid IS NULL OR v_raw_rid <= 0 OR v_raw_rid <> TRUNC(v_raw_rid) THEN
        RAISE_APPLICATION_ERROR(-20304, 'All room_ids must be positive integers.');
      END IF;

      v_rid := v_raw_rid;
      IF v_room_rates.EXISTS(v_rid) THEN
        RAISE_APPLICATION_ERROR(-20304, 'Duplicate room_id ' || v_rid || ' in booking request.');
      END IF;

      v_room_rates(v_rid) := NULL;
    END LOOP;

    IF v_room_rates.COUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20304, 'At least one room_id must be provided.');
    END IF;

    -- 2. Lock every requested room in strictly ascending room_id order, verify status,
    --    and check date-range overlaps while holding the row locks.
    v_rid := v_room_rates.FIRST;
    WHILE v_rid IS NOT NULL LOOP
      BEGIN
        SELECT r.status, rt.base_nightly_rate
          INTO v_room_status, v_nightly_rate
          FROM hotel_app.rooms r
          JOIN hotel_app.room_types rt
            ON rt.room_type_id = r.room_type_id
         WHERE r.room_id   = v_rid
           AND r.is_active = 'Y'
           FOR UPDATE OF r.room_id WAIT 5;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE_APPLICATION_ERROR(-20302, 'Room ID ' || v_rid || ' does not exist or is inactive.');
        WHEN e_lock_timeout THEN
          RAISE_APPLICATION_ERROR(
            -20305,
            'Room ID ' || v_rid || ' is busy under concurrent reservation (ORA-30006); please retry.'
          );
      END;

      IF v_room_status IN ('MAINTENANCE', 'OUT_OF_SERVICE') THEN
        RAISE_APPLICATION_ERROR(-20302, 'Room ID ' || v_rid || ' is currently ' || v_room_status || '.');
      END IF;

      -- Half-open interval overlap check: [existing_in, existing_out) intersects [v_check_in, v_check_out)
      -- Excludes CANCELLED and CHECKED_OUT reservations; uses covering index idx_br_room_dates.
      SELECT COUNT(*)
        INTO v_overlap_count
        FROM hotel_app.booking_rooms br
        JOIN hotel_app.bookings b
          ON b.booking_id = br.booking_id
       WHERE br.room_id        = v_rid
         AND b.booking_status IN ('PENDING', 'CONFIRMED', 'CHECKED_IN')
         AND br.check_in_date  < v_check_out
         AND br.check_out_date > v_check_in;

      IF v_overlap_count > 0 THEN
        RAISE_APPLICATION_ERROR(
          -20302,
          'Room ID ' || v_rid || ' is already booked for overlapping dates (' ||
          TO_CHAR(v_check_in, 'YYYY-MM-DD') || ' to ' || TO_CHAR(v_check_out, 'YYYY-MM-DD') || ').'
        );
      END IF;

      v_room_rates(v_rid) := v_nightly_rate;
      v_rid := v_room_rates.NEXT(v_rid);
    END LOOP;

    -- 3. Generate unique reference and insert booking atomically with RETURNING INTO
    o_booking_ref := 'BK-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-' ||
                     LPAD(hotel_app.seq_booking_ref.NEXTVAL, 8, '0');

    INSERT INTO hotel_app.bookings (
      booking_ref, customer_id, check_in_date, check_out_date, booking_status
    ) VALUES (
      o_booking_ref, p_customer_id, v_check_in, v_check_out, 'CONFIRMED'
    )
    RETURNING booking_id INTO o_booking_id;

    -- 4. Link all reserved rooms with their snapshotted nightly rates
    v_rid := v_room_rates.FIRST;
    WHILE v_rid IS NOT NULL LOOP
      INSERT INTO hotel_app.booking_rooms (
        booking_id, room_id, check_in_date, check_out_date, agreed_nightly_rate
      ) VALUES (
        o_booking_id, v_rid, v_check_in, v_check_out, v_room_rates(v_rid)
      )
      RETURNING booking_room_id INTO v_booking_room_id;

      v_rid := v_room_rates.NEXT(v_rid);
    END LOOP;
  END create_multi_room_booking;

  PROCEDURE create_booking (
    p_customer_id    IN  hotel_app.customers.customer_id%TYPE,
    p_room_id        IN  hotel_app.rooms.room_id%TYPE,
    p_check_in_date  IN  DATE,
    p_check_out_date IN  DATE,
    o_booking_id     OUT hotel_app.bookings.booking_id%TYPE,
    o_booking_ref    OUT hotel_app.bookings.booking_ref%TYPE
  ) IS
  BEGIN
    create_multi_room_booking(
      p_customer_id    => p_customer_id,
      p_room_ids       => t_room_id_tab(p_room_id),
      p_check_in_date  => p_check_in_date,
      p_check_out_date => p_check_out_date,
      o_booking_id     => o_booking_id,
      o_booking_ref    => o_booking_ref
    );
  END create_booking;

  PROCEDURE add_service_order (
    p_booking_id       IN  hotel_app.bookings.booking_id%TYPE,
    p_service_id       IN  hotel_app.services.service_id%TYPE,
    p_quantity         IN  hotel_app.service_orders.quantity%TYPE,
    o_service_order_id OUT hotel_app.service_orders.service_order_id%TYPE
  ) IS
    v_booking_status hotel_app.bookings.booking_status%TYPE;
    v_unit_price     hotel_app.services.unit_price%TYPE;
  BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
      RAISE_APPLICATION_ERROR(-20304, 'Service order quantity must be positive.');
    END IF;

    -- Lock parent booking row to prevent adding orders to a concurrently cancelled booking
    BEGIN
      SELECT booking_status
        INTO v_booking_status
        FROM hotel_app.bookings
       WHERE booking_id = p_booking_id
         FOR UPDATE WAIT 5;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20303, 'Booking ID ' || p_booking_id || ' not found.');
      WHEN e_lock_timeout THEN
        RAISE_APPLICATION_ERROR(
          -20305,
          'Booking ID ' || p_booking_id || ' is currently locked by another session (ORA-30006); please retry.'
        );
    END;

    IF v_booking_status IN ('CANCELLED', 'CHECKED_OUT') THEN
      RAISE_APPLICATION_ERROR(-20304, 'Cannot add service orders to booking in status ' || v_booking_status || '.');
    END IF;

    BEGIN
      SELECT unit_price
        INTO v_unit_price
        FROM hotel_app.services
       WHERE service_id = p_service_id
         AND is_active  = 'Y';
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20304, 'Service ID ' || p_service_id || ' does not exist or is inactive.');
    END;

    INSERT INTO hotel_app.service_orders (
      booking_id, service_id, quantity, unit_price_snapshot
    ) VALUES (
      p_booking_id, p_service_id, p_quantity, v_unit_price
    )
    RETURNING service_order_id INTO o_service_order_id;
  END add_service_order;

  PROCEDURE calculate_invoice_total (
    p_booking_id   IN  hotel_app.bookings.booking_id%TYPE,
    p_tax_rate     IN  NUMBER DEFAULT 0.10,
    o_invoice_id   OUT hotel_app.invoices.invoice_id%TYPE,
    o_total_amount OUT hotel_app.invoices.total_amount%TYPE
  ) IS
    v_booking_status   hotel_app.bookings.booking_status%TYPE;
    v_room_subtotal    NUMBER(12,2);
    v_service_subtotal NUMBER(12,2);
    v_tax_amount       NUMBER(12,2);
  BEGIN
    IF p_tax_rate IS NULL OR p_tax_rate < 0 OR p_tax_rate > 0.50 THEN
      RAISE_APPLICATION_ERROR(-20304, 'Tax rate must be a non-null number between 0.00 and 0.50.');
    END IF;

    -- Serialize invoice generation for this booking
    BEGIN
      SELECT booking_status
        INTO v_booking_status
        FROM hotel_app.bookings
       WHERE booking_id = p_booking_id
         FOR UPDATE WAIT 5;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20303, 'Booking ID ' || p_booking_id || ' not found.');
      WHEN e_lock_timeout THEN
        RAISE_APPLICATION_ERROR(
          -20305,
          'Booking ID ' || p_booking_id || ' is currently locked by another session (ORA-30006); please retry.'
        );
    END;

    IF v_booking_status = 'CANCELLED' THEN
      RAISE_APPLICATION_ERROR(-20304, 'Cannot issue invoice for CANCELLED booking ID ' || p_booking_id || '.');
    END IF;

    -- Exact multi-room / multi-night set-based SQL aggregation scoped strictly to p_booking_id
    SELECT NVL(SUM((br.check_out_date - br.check_in_date) * br.agreed_nightly_rate), 0)
      INTO v_room_subtotal
      FROM hotel_app.booking_rooms br
     WHERE br.booking_id = p_booking_id;

    SELECT NVL(SUM(so.quantity * so.unit_price_snapshot), 0)
      INTO v_service_subtotal
      FROM hotel_app.service_orders so
     WHERE so.booking_id = p_booking_id;

    v_tax_amount   := ROUND((v_room_subtotal + v_service_subtotal) * p_tax_rate, 2);
    o_total_amount := v_room_subtotal + v_service_subtotal + v_tax_amount;

    -- Idempotent upsert into invoices
    MERGE INTO hotel_app.invoices inv
    USING (SELECT p_booking_id AS booking_id FROM dual) src
       ON (inv.booking_id = src.booking_id)
    WHEN MATCHED THEN
      UPDATE SET inv.room_subtotal    = v_room_subtotal,
                 inv.service_subtotal = v_service_subtotal,
                 inv.tax_amount       = v_tax_amount,
                 inv.total_amount     = o_total_amount,
                 inv.invoice_status   = 'ISSUED',
                 inv.issued_at        = SYSTIMESTAMP
    WHEN NOT MATCHED THEN
      INSERT (booking_id, room_subtotal, service_subtotal, tax_amount, total_amount, invoice_status, issued_at)
      VALUES (p_booking_id, v_room_subtotal, v_service_subtotal, v_tax_amount, o_total_amount, 'ISSUED', SYSTIMESTAMP);

    SELECT invoice_id
      INTO o_invoice_id
      FROM hotel_app.invoices
     WHERE booking_id = p_booking_id;
  END calculate_invoice_total;

  PROCEDURE cancel_booking (
    p_booking_id IN hotel_app.bookings.booking_id%TYPE
  ) IS
    v_status   hotel_app.bookings.booking_status%TYPE;
    v_paid_cnt PLS_INTEGER;
  BEGIN
    BEGIN
      SELECT booking_status
        INTO v_status
        FROM hotel_app.bookings
       WHERE booking_id = p_booking_id
         FOR UPDATE WAIT 5;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20303, 'Booking ID ' || p_booking_id || ' not found.');
      WHEN e_lock_timeout THEN
        RAISE_APPLICATION_ERROR(
          -20305,
          'Booking ID ' || p_booking_id || ' is currently locked by another session (ORA-30006); please retry.'
        );
    END;

    IF v_status IN ('CHECKED_OUT', 'CANCELLED') THEN
      RAISE_APPLICATION_ERROR(-20304, 'Booking ID ' || p_booking_id || ' cannot be cancelled from status ' || v_status || '.');
    END IF;

    SELECT COUNT(*)
      INTO v_paid_cnt
      FROM hotel_app.invoices
     WHERE booking_id     = p_booking_id
       AND invoice_status = 'PAID';

    IF v_paid_cnt > 0 THEN
      RAISE_APPLICATION_ERROR(-20304, 'Booking ID ' || p_booking_id || ' has a PAID invoice; issue a refund before cancelling.');
    END IF;

    UPDATE hotel_app.bookings
       SET booking_status = 'CANCELLED',
           updated_at     = SYSTIMESTAMP
     WHERE booking_id = p_booking_id;

    -- Void any unpaid draft/issued invoice linked to this cancelled reservation
    UPDATE hotel_app.invoices
       SET invoice_status = 'VOID'
     WHERE booking_id     = p_booking_id
       AND invoice_status IN ('DRAFT', 'ISSUED');
  END cancel_booking;

END pkg_hotel_booking;
/
SHOW ERRORS PACKAGE BODY hotel_app.pkg_hotel_booking

-- Least-privilege execution grant: front-desk clerks use the safe package API
GRANT EXECUTE ON hotel_app.pkg_hotel_booking TO role_hotel_clerk;
