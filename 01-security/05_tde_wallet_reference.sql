-- ============================================================================
-- File:        01-security/05_tde_wallet_reference.sql
-- Purpose:     Transparent Data Encryption (TDE) Software Keystore & Auto-Login
--              Wallet Architecture Reference (Oracle 19c / 23ai Modern Syntax).
--
-- IMPORTANT LICENSING & RUNTIME NOTE:
--   * TDE requires Oracle Enterprise Edition + Advanced Security Option (ASO),
--     or Oracle Cloud Base Database / Autonomous Database (where TDE is included).
--   * Oracle 23ai Free does NOT license or execute TDE DDL (raises ORA-00439:
--     feature not enabled). DO NOT run this script against the local Free lab
--     container — this file is an Enterprise production reference blueprint
--     following modern Oracle 19c/23ai WALLET_ROOT best practices (replacing
--     deprecated sqlnet.ora ENCRYPTION_WALLET_LOCATION).
--   * NEVER commit real keystore passwords. Always supply &TDE_KEYSTORE_PWD
--     interactively or via an enterprise secrets manager (HashiCorp Vault / OCI Vault).
-- ============================================================================

SET ECHO ON
SET VERIFY OFF

-- Prompt interactively for keystore password (never store in plaintext SQL)
ACCEPT TDE_KEYSTORE_PWD CHAR PROMPT 'Enter TDE Software Keystore Password: ' HIDE

-- ============================================================================
-- STEP 1: Configure WALLET_ROOT & TDE_CONFIGURATION in CDB$ROOT
--         (Replaces deprecated sqlnet.ora ENCRYPTION_WALLET_LOCATION)
-- ============================================================================
-- Pre-requisite on OS host (owned by oracle:oinstall, mode 0700):
--   mkdir -p /opt/oracle/admin/FREE/wallet/tde
--   chmod 700 /opt/oracle/admin/FREE/wallet /opt/oracle/admin/FREE/wallet/tde

ALTER SESSION SET CONTAINER = CDB$ROOT;

-- Static parameter: requires instance bounce once
ALTER SYSTEM SET WALLET_ROOT = '/opt/oracle/admin/FREE/wallet' SCOPE = SPFILE;

-- Restart CDB instance after setting WALLET_ROOT:
--   SHUTDOWN IMMEDIATE;
--   STARTUP;

-- Dynamic parameter (set after restart):
ALTER SYSTEM SET TDE_CONFIGURATION = 'KEYSTORE_CONFIGURATION=FILE' SCOPE = BOTH;

-- ============================================================================
-- STEP 2: Create Password-Protected Software Keystore (PKCS#12)
-- ============================================================================
ADMINISTER KEY MANAGEMENT CREATE KEYSTORE '/opt/oracle/admin/FREE/wallet/tde'
  IDENTIFIED BY "&TDE_KEYSTORE_PWD";

-- Open keystore across CDB$ROOT and all open PDBs
ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN
  IDENTIFIED BY "&TDE_KEYSTORE_PWD"
  CONTAINER = ALL;

-- ============================================================================
-- STEP 3: Generate Master Encryption Key (MEK) with Automatic Keystore Backup
-- ============================================================================
-- Always use WITH BACKUP so pre-change ewallet.p12 is archived automatically.
ADMINISTER KEY MANAGEMENT SET KEY
  FORCE KEYSTORE
  IDENTIFIED BY "&TDE_KEYSTORE_PWD"
  WITH BACKUP USING 'initial_tde_mek_cdb'
  CONTAINER = ALL;

-- ============================================================================
-- STEP 4: Create Local Auto-Login Keystore (cwallet.sso)
--   * Allows unattended database / PDB restarts without storing passwords in scripts.
--   * LOCAL auto-login binds cwallet.sso to the current host (stronger than
--     portable AUTO_LOGIN if backup media is ever misplaced).
-- ============================================================================
ADMINISTER KEY MANAGEMENT CREATE LOCAL AUTO_LOGIN KEYSTORE
  FROM KEYSTORE '/opt/oracle/admin/FREE/wallet/tde'
  IDENTIFIED BY "&TDE_KEYSTORE_PWD";

-- ============================================================================
-- STEP 5: Encrypt Application Tablespaces (AES256) in FREEPDB1
-- ============================================================================
ALTER SESSION SET CONTAINER = FREEPDB1;

-- Option A: Provision a new encrypted tablespace for PII / payment data
CREATE TABLESPACE ts_hotel_pii_enc
  DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/ts_hotel_pii_enc01.dbf'
  SIZE 128M AUTOEXTEND ON NEXT 64M MAXSIZE 2G
  ENCRYPTION USING 'AES256'
  DEFAULT STORAGE (ENCRYPT);

-- Option B: Zero-downtime Online Encryption of an existing tablespace (12.2+/19c/23ai)
--   Note: Requires COMPATIBLE >= 12.2.0.0 and temporary free disk space >= datafile size.
ALTER TABLESPACE ts_hotel_data
  ENCRYPTION ONLINE USING 'AES256' ENCRYPT;

-- ============================================================================
-- STEP 6: Periodic Master Key Rotation (Compliance: PCI-DSS / SOC2 Annual Rekey)
-- ============================================================================
-- Notes:
--   * Rotating the Master Encryption Key re-encrypts ONLY the tablespace keys
--     in the data dictionary headers (instantaneous; zero table rewrites).
--   * FORCE KEYSTORE is mandatory once an auto-login keystore (cwallet.sso) is
--     open; without it, SET KEY fails with ORA-28417. Oracle atomically updates
--     both ewallet.p12 and cwallet.sso during rotation.
ADMINISTER KEY MANAGEMENT SET KEY
  FORCE KEYSTORE
  IDENTIFIED BY "&TDE_KEYSTORE_PWD"
  WITH BACKUP USING 'annual_mek_rotation'
  CONTAINER = CURRENT;

-- ============================================================================
-- STEP 7: Operational Verification Queries
-- ============================================================================
SELECT con_id, wrl_type, wrl_parameter, status, wallet_type, keystore_mode
  FROM v$encryption_wallet
 ORDER BY con_id;

SELECT tablespace_name, encrypted
  FROM dba_tablespaces
 WHERE tablespace_name LIKE 'TS_%'
 ORDER BY tablespace_name;

-- Multitenant-safe join: always match BOTH ts# AND con_id across containers
SELECT t.con_id, t.name AS tablespace_name, e.encryptionalg, e.status, e.key_version
  FROM v$encrypted_tablespaces e
  JOIN v$tablespace t
    ON t.ts#    = e.ts#
   AND t.con_id = e.con_id
 ORDER BY t.con_id, t.name;
