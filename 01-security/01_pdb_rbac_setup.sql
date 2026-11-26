-- ============================================================================
-- File:        01-security/01_pdb_rbac_setup.sql
-- Purpose:     Multitenant PDB Least-Privilege RBAC, Tablespace Isolation,
--              and Password Profile Hardening for Oracle 23ai Free (FREEPDB1)
-- Execution:   Run as SYSDBA inside the CDB; switches explicitly into FREEPDB1.
--              Pass passwords via SQL*Plus substitution variables (never
--              hardcode real credentials in source control):
--                sqlplus / as sysdba @01_pdb_rbac_setup.sql
-- ============================================================================

WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET SERVEROUTPUT ON
SET VERIFY OFF

-- 1. Switch into the target Pluggable Database (local PDB provisioning only)
ALTER SESSION SET CONTAINER = FREEPDB1;

SHOW CON_NAME

-- Enforce kernel resource limits (IDLE_TIME, SESSIONS_PER_USER, CONNECT_TIME) in this PDB
ALTER SYSTEM SET RESOURCE_LIMIT = TRUE SCOPE = BOTH;

-- Prompt/define placeholder variables if not supplied by caller
ACCEPT SEC_ADMIN_PWD   CHAR PROMPT 'Enter password for SEC_ADMIN: ' HIDE
ACCEPT HOTEL_APP_PWD   CHAR PROMPT 'Enter password for HOTEL_APP: ' HIDE
ACCEPT HR_PAYROLL_PWD  CHAR PROMPT 'Enter password for HR_PAYROLL_MGR: ' HIDE
ACCEPT CLERK_DEMO_PWD  CHAR PROMPT 'Enter password for CLERK_ALICE / CLERK_BOB: ' HIDE
ACCEPT AUDITOR_DEMO_PWD CHAR PROMPT 'Enter password for SEC_AUDITOR: ' HIDE

-- 2. Dedicated Tablespaces with Bounded Autoextend (prevent disk exhaustion)
CREATE TABLESPACE ts_hotel_data
  DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/ts_hotel_data01.dbf'
  SIZE 256M AUTOEXTEND ON NEXT 64M MAXSIZE 2G
  EXTENT MANAGEMENT LOCAL AUTOALLOCATE
  SEGMENT SPACE MANAGEMENT AUTO;

CREATE TABLESPACE ts_hotel_idx
  DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/ts_hotel_idx01.dbf'
  SIZE 128M AUTOEXTEND ON NEXT 64M MAXSIZE 1G
  EXTENT MANAGEMENT LOCAL AUTOALLOCATE
  SEGMENT SPACE MANAGEMENT AUTO;

CREATE TABLESPACE ts_sec_data
  DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/ts_sec_data01.dbf'
  SIZE 64M AUTOEXTEND ON NEXT 32M MAXSIZE 512M
  EXTENT MANAGEMENT LOCAL AUTOALLOCATE
  SEGMENT SPACE MANAGEMENT AUTO;

-- 3. Hardened Security Profile (CIS Oracle Benchmark aligned)
--    Note: In production, also run @?/rdbms/admin/utlpwdmg.sql and attach
--          PASSWORD_VERIFY_FUNCTION ora12c_strong_verify_function.
CREATE PROFILE prof_app_standard LIMIT
  FAILED_LOGIN_ATTEMPTS     5
  PASSWORD_LOCK_TIME        1/24          -- 1 hour lockout
  PASSWORD_LIFE_TIME        90            -- 90-day rotation
  PASSWORD_GRACE_TIME       7
  PASSWORD_REUSE_TIME       365
  PASSWORD_REUSE_MAX        5
  IDLE_TIME                 30            -- Disconnect idle sessions after 30 min
  SESSIONS_PER_USER         15
  CONNECT_TIME              480;

-- 4. Least-Privilege Roles (Separation of Duties)
CREATE ROLE role_hotel_owner;
CREATE ROLE role_hotel_clerk;
CREATE ROLE role_hr_payroll_admin;
CREATE ROLE role_sec_auditor;

-- Schema owner role: strictly scoped DDL needed for OLTP deployment
GRANT CREATE SESSION,
      CREATE TABLE,
      CREATE VIEW,
      CREATE SEQUENCE,
      CREATE PROCEDURE,
      CREATE TRIGGER
   TO role_hotel_owner;

-- Runtime application clerk role: session only (object EXECUTE granted explicitly)
GRANT CREATE SESSION TO role_hotel_clerk;

-- HR Payroll admin role: authorized to view/update payroll compensation rows
GRANT CREATE SESSION TO role_hr_payroll_admin;

-- Security auditor role: read-only visibility into Unified Audit & FGA metadata
GRANT CREATE SESSION, AUDIT_VIEWER TO role_sec_auditor;

-- 5. Local PDB Users with Explicit Tablespace Quotas (Zero Unlimited Quotas)
CREATE USER sec_admin
  IDENTIFIED BY "&SEC_ADMIN_PWD"
  DEFAULT TABLESPACE ts_sec_data
  TEMPORARY TABLESPACE temp
  QUOTA 256M ON ts_sec_data
  PROFILE prof_app_standard
  ACCOUNT UNLOCK;

GRANT CREATE SESSION,
      CREATE TABLE,
      CREATE VIEW,
      CREATE PROCEDURE,
      CREATE SEQUENCE,
      CREATE ANY CONTEXT,
      CREATE JOB
   TO sec_admin;

-- Explicit package grants required for VPD, FGA, DBMS_ASSERT, and audit cleanup
GRANT EXECUTE ON SYS.DBMS_ASSERT     TO sec_admin;
GRANT EXECUTE ON SYS.DBMS_RLS        TO sec_admin;
GRANT EXECUTE ON SYS.DBMS_FGA        TO sec_admin;
GRANT EXECUTE ON SYS.DBMS_AUDIT_MGMT TO sec_admin;
GRANT AUDIT_ADMIN                    TO sec_admin;

-- Explicit direct read-only dictionary/V$ grants (needed inside AUTHID DEFINER
-- VPD context package and for Shared Pool / Audit verification queries)
GRANT SELECT ON SYS.DBA_ROLE_PRIVS               TO sec_admin;
GRANT SELECT ON SYS.DBA_POLICIES                 TO sec_admin;
GRANT SELECT ON SYS.DBA_AUDIT_POLICIES           TO sec_admin;
GRANT SELECT ON SYS.DBA_AUDIT_MGMT_CLEANUP_JOBS  TO sec_admin;
GRANT SELECT ON SYS.DBA_AUDIT_MGMT_LAST_ARCH_TS  TO sec_admin;
GRANT SELECT ON SYS.V_$SQL                       TO sec_admin;
GRANT SELECT ON SYS.V_$SQL_SHARED_CURSOR         TO sec_admin;
GRANT SELECT ON SYS.V_$VPD_POLICY                TO sec_admin;

CREATE USER hotel_app
  IDENTIFIED BY "&HOTEL_APP_PWD"
  DEFAULT TABLESPACE ts_hotel_data
  TEMPORARY TABLESPACE temp
  QUOTA 1536M ON ts_hotel_data
  QUOTA 768M  ON ts_hotel_idx
  PROFILE prof_app_standard
  ACCOUNT UNLOCK;

GRANT role_hotel_owner TO hotel_app;

-- Required by benchmark script (04_benchmark_xplan.sql) for execution plan diagnostics
GRANT SELECT ON SYS.V_$SESSION           TO hotel_app;
GRANT SELECT ON SYS.V_$SQL               TO hotel_app;
GRANT SELECT ON SYS.V_$SQL_PLAN          TO hotel_app;
GRANT SELECT ON SYS.V_$SQL_PLAN_STATISTICS_ALL TO hotel_app;
GRANT SELECT ON SYS.V_$MYSTAT            TO hotel_app;
GRANT SELECT ON SYS.V_$STATNAME          TO hotel_app;

CREATE USER hr_payroll_mgr
  IDENTIFIED BY "&HR_PAYROLL_PWD"
  DEFAULT TABLESPACE ts_sec_data
  TEMPORARY TABLESPACE temp
  QUOTA 0 ON ts_sec_data
  PROFILE prof_app_standard
  ACCOUNT UNLOCK;

GRANT role_hr_payroll_admin TO hr_payroll_mgr;

CREATE USER clerk_alice
  IDENTIFIED BY "&CLERK_DEMO_PWD"
  DEFAULT TABLESPACE ts_hotel_data
  TEMPORARY TABLESPACE temp
  QUOTA 0 ON ts_hotel_data
  PROFILE prof_app_standard
  ACCOUNT UNLOCK;

GRANT role_hotel_clerk TO clerk_alice;

CREATE USER clerk_bob
  IDENTIFIED BY "&CLERK_DEMO_PWD"
  DEFAULT TABLESPACE ts_hotel_data
  TEMPORARY TABLESPACE temp
  QUOTA 0 ON ts_hotel_data
  PROFILE prof_app_standard
  ACCOUNT UNLOCK;

GRANT role_hotel_clerk TO clerk_bob;

CREATE USER sec_auditor
  IDENTIFIED BY "&AUDITOR_DEMO_PWD"
  DEFAULT TABLESPACE ts_sec_data
  TEMPORARY TABLESPACE temp
  QUOTA 0 ON ts_sec_data
  PROFILE prof_app_standard
  ACCOUNT UNLOCK;

GRANT role_sec_auditor TO sec_auditor;

-- 6. Verification Report
PROMPT === Local PDB Users Provisioned ===
SELECT username, account_status, default_tablespace, profile, common
  FROM dba_users
 WHERE username IN ('SEC_ADMIN', 'HOTEL_APP', 'HR_PAYROLL_MGR', 'CLERK_ALICE', 'CLERK_BOB', 'SEC_AUDITOR')
 ORDER BY username;

PROMPT === Explicit Tablespace Quotas ===
SELECT username, tablespace_name, ROUND(max_bytes / 1024 / 1024, 1) AS max_mb
  FROM dba_ts_quotas
 WHERE username IN ('SEC_ADMIN', 'HOTEL_APP')
 ORDER BY username, tablespace_name;

PROMPT === Role Assignments ===
SELECT grantee, granted_role, admin_option
  FROM dba_role_privs
 WHERE grantee IN ('SEC_ADMIN', 'HOTEL_APP', 'HR_PAYROLL_MGR', 'CLERK_ALICE', 'CLERK_BOB', 'SEC_AUDITOR')
 ORDER BY grantee, granted_role;
