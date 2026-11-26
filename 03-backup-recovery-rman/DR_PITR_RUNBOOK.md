# Oracle RMAN Point-in-Time Recovery (PITR) & Table Recovery DR Runbook

> **Scope:** Multitenant Oracle Database (`FREE` CDB / `FREEPDB1` PDB) running the `HOTEL_APP` OLTP workload.
> **Audience:** On-call Mid-to-Senior DBA / DBRE executing planned DR drills or emergency logical-corruption recovery.

---

## 1. Prerequisites & Pre-Flight Verification

Online RMAN backups and Point-in-Time Recovery (PITR) strictly require **ARCHIVELOG** mode and valid backup pieces.

### 1.1 Enable ARCHIVELOG Mode (One-Time Setup on Lab Container)

```sql
-- Connect as SYSDBA in CDB$ROOT
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;

-- Verify ARCHIVELOG mode and FRA destination
ARCHIVE LOG LIST;
SELECT name, open_mode, log_mode, flashback_on FROM v$database;
```

### 1.2 Validate Backup Recoverability Before Any Drill (Dry-Run)

```bash
rman target / <<'EOF'
LIST BACKUP SUMMARY;
RESTORE PLUGGABLE DATABASE FREEPDB1 VALIDATE;
RESTORE DATABASE VALIDATE HEADER;
EOF
```

Expected outcome: Zero `RMAN-` errors and `Finished restore` with all datafiles and archived redo logs verified readable on disk.

---

## 2. Scenario A — Online Pluggable Database (PDB) Point-in-Time Recovery (PITR)

**Use Case:** Accidental mass `DELETE`, corrupted batch deployment, or dropped schema inside `FREEPDB1` at `2026-11-26 14:25:00 UTC`. Other PDBs in the CDB remain online without interruption.

### Step 1: Identify Exact Target Time or SCN

If Flashback Query or LogMiner is available, pinpoint the exact timestamp immediately preceding the incident:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;
SELECT TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS') AS current_utc,
       CURRENT_SCN
  FROM v$database;
```

### Step 2: Prepare Auxiliary Directory (for RMAN Automated Auxiliary Instance)

```bash
mkdir -p /opt/oracle/rman_aux
chmod 750 /opt/oracle/rman_aux
```

### Step 3: Execute PDB PITR via RMAN

> **Multitenant Local Undo Note (Oracle 19c / 23ai):** Modern CDBs run in **Local Undo Mode** by default (`PROPERTY_NAME = 'LOCAL_UNDO_ENABLED'`), allowing RMAN to perform PDB PITR directly using the PDB's local undo tablespace without cloning `CDB$ROOT`. Supplying `AUXILIARY DESTINATION` remains best practice as an automatic fallback for legacy Shared Undo CDBs. You may also substitute `SET UNTIL SCN <target_scn>;` when an exact SCN is known.

```bash
rman target / <<'EOF'
RUN {
  ALTER PLUGGABLE DATABASE FREEPDB1 CLOSE IMMEDIATE;
  SET UNTIL TIME "TO_DATE('2026-11-26 14:24:00', 'YYYY-MM-DD HH24:MI:SS')";
  RESTORE PLUGGABLE DATABASE FREEPDB1;
  RECOVER PLUGGABLE DATABASE FREEPDB1
    AUXILIARY DESTINATION '/opt/oracle/rman_aux';
  ALTER PLUGGABLE DATABASE FREEPDB1 OPEN RESETLOGS;
}
EOF
```

### Step 4: Mandatory Immediate Post-RESETLOGS Level 0 Backup

After `OPEN RESETLOGS` on a PDB or CDB, a new incarnation branch is created. Immediately trigger a fresh Level 0 backup:

```bash
./run_rman_backup.sh full
```

---

## 3. Scenario B — Granular Single-Table Recovery (`RMAN RECOVER TABLE`)

**Use Case:** Only `HOTEL_APP.BOOKINGS` (or `HOTEL_APP.INVOICES`) was accidentally truncated or corrupted while all other tables in `FREEPDB1` have valid recent transactions that must NOT be rolled back.

Oracle RMAN automates spinning up a temporary auxiliary CDB/PDB, recovering to the target timestamp/SCN, exporting the target table via Data Pump, and importing it back under a remapped name so the DBA can reconcile rows safely before swapping!

> **Capacity Pre-Check:** Ensure `AUXILIARY DESTINATION` has enough free disk space to hold temporary restored copies of `SYSTEM`, `SYSAUX`, `UNDO`, and the target table's tablespace (`TS_HOTEL_DATA`). Using `REMAP TABLE` into a staging table avoids foreign-key conflicts with live child rows (`BOOKING_ROOMS`, `SERVICE_ORDERS`, `INVOICES`).

```bash
mkdir -p /opt/oracle/rman_aux /opt/oracle/rman_datapump

rman target / <<'EOF'
RECOVER TABLE HOTEL_APP.BOOKINGS OF PLUGGABLE DATABASE FREEPDB1
  UNTIL TIME "TO_DATE('2026-11-26 14:24:00', 'YYYY-MM-DD HH24:MI:SS')"
  AUXILIARY DESTINATION '/opt/oracle/rman_aux'
  DATAPUMP DESTINATION '/opt/oracle/rman_datapump'
  DUMP FILE 'bookings_pitr_recovery.dmp'
  REMAP TABLE 'HOTEL_APP'.'BOOKINGS':'BOOKINGS_RECOVERED_DR';
EOF
```

### Reconcile & Merge Recovered Data Back Into Production Table

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;

-- 1. Inspect missing rows between live table and recovered snapshot
SELECT COUNT(*) AS recovered_rows FROM hotel_app.bookings_recovered_dr;
SELECT COUNT(*) AS missing_rows
  FROM hotel_app.bookings_recovered_dr r
 WHERE NOT EXISTS (
         SELECT 1 FROM hotel_app.bookings live WHERE live.booking_id = r.booking_id
       );

-- 2. Re-insert verified missing rows inside a controlled transaction
INSERT INTO hotel_app.bookings (
  booking_id, booking_ref, customer_id, check_in_date, check_out_date,
  booking_status, created_at, updated_at
)
SELECT booking_id, booking_ref, customer_id, check_in_date, check_out_date,
       booking_status, created_at, updated_at
  FROM hotel_app.bookings_recovered_dr r
 WHERE NOT EXISTS (
         SELECT 1 FROM hotel_app.bookings live WHERE live.booking_id = r.booking_id
       );

COMMIT;

-- 3. Realign the GENERATED BY DEFAULT AS IDENTITY sequence above MAX(booking_id)
--    so subsequent application inserts never hit ORA-00001
ALTER TABLE hotel_app.bookings
  MODIFY booking_id GENERATED BY DEFAULT AS IDENTITY (START WITH LIMIT VALUE);

-- 4. Drop temporary staging table after business sign-off
DROP TABLE hotel_app.bookings_recovered_dr PURGE;
```

---

## 4. Post-Recovery Validation Checklist

| # | Check | Command / Query | Pass Criteria |
|---|-------|-----------------|---------------|
| 1 | PDB Open Mode | `SELECT name, open_mode, restricted FROM v$pdbs;` | `FREEPDB1` is `READ WRITE`, `RESTRICTED = NO` |
| 2 | Invalid Objects | `SELECT owner, object_type, COUNT(*) FROM dba_objects WHERE status <> 'VALID' GROUP BY owner, object_type;` | `0` invalid objects in `HOTEL_APP` & `SEC_ADMIN` (run `@?/rdbms/admin/utlrp.sql` if needed) |
| 3 | Data Integrity | Row counts on `bookings`, `booking_rooms`, `service_orders`, `invoices` + FK validation | Matches expected pre-incident counts; zero orphaned FKs |
| 4 | Sequence Alignment | Verify `seq_booking_ref` & `IDENTITY` sequences exceed `MAX(id)` (realign via `MODIFY ... (START WITH LIMIT VALUE)`) | Zero `ORA-00001` unique constraint violations on test insert |
| 5 | Alert Log Scan | Inspect `V$DIAG_ALERT_EXT` for `ORA-` / corruption messages | Zero block corruption (`ORA-01578`) or media errors |
| 6 | Fresh Baseline Backup | `./run_rman_backup.sh full` | Exit code `0`, `LIST BACKUP SUMMARY` confirms new Level 0 |

---

## 5. RPO / RTO Validation Metrics Template

Record actual timings during every quarterly DR drill to verify SLA compliance:

| Metric | Target SLA | Measured Drill Value | Verification Method |
|--------|------------|----------------------|---------------------|
| **RPO** (Recovery Point Objective) | `<= 15 minutes` (or `0` with Data Guard sync) | `___ min` | Delta between last committed txn before incident and `MAX(created_at)` post-recovery |
| **RTO** (Recovery Time Objective — PDB PITR) | `<= 30 minutes` | `___ min` | Wall-clock time from incident declaration to `FREEPDB1 OPEN READ WRITE` + app smoke test |
| **RTO** (Granular Table Recovery) | `<= 45 minutes` | `___ min` | Wall-clock time from `RECOVER TABLE` start to verified row reconciliation |
| **Backup Compression Ratio** | `>= 3.0x` | `___ x` | `SELECT compression_ratio FROM v$rman_backup_job_details ORDER BY start_time DESC FETCH FIRST 1 ROW ONLY;` |
| **Backup Validation Status** | `100% PASS` | `PASS / FAIL` | `RESTORE PLUGGABLE DATABASE FREEPDB1 VALIDATE` exit status |
