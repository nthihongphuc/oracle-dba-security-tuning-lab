"""
Static hygiene, security & Oracle 19c/23ai internals verification suite
for the Oracle 23ai DBA Engineering Lab.

Validates all SQL, RMAN, Shell, Markdown, and Docker Compose artifacts against
Staff Oracle DBA standards:
  - Zero hidden CDB scripting anti-patterns (_ORACLE_SCRIPT)
  - Zero excessive privilege grants (GRANT ALL PRIVILEGES)
  - Zero hardcoded SYS, user, or TDE keystore passwords
  - Pure LF line endings on all shell scripts (no Windows CRLF)
  - Zero single-level large CONNECT BY generators (prevents ORA-30009 on 2 GB RAM)
  - Safe DBMS_RLS.STATIC usage (zero PL/SQL user-branching inside policy function)
  - Rollback-safe PRAGMA AUTONOMOUS_TRANSACTION blocks (prevents ORA-06519)
  - SET SERVEROUTPUT OFF before DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, ...)
  - Multitenant-safe DBMS_AUDIT_MGMT (CONTAINER_CURRENT, UTC watermark, AUTHID CURRENT_USER)
  - Multi-room deadlock-free lock ordering & ORA-30006 handling in pkg_hotel_booking
  - Proper docker-compose.yml environment variable substitution
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Iterable

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent

SQL_FILES = sorted(REPO_ROOT.glob("*/*.sql"))
DIAGNOSTIC_SQL_FILES = sorted((REPO_ROOT / "04-diagnostics").glob("*.sql"))
SHELL_FILES = sorted(REPO_ROOT.glob("*/*.sh"))
RCV_FILES = sorted(REPO_ROOT.glob("*/*.rcv"))
ALL_SCRIPT_FILES = SQL_FILES + SHELL_FILES + RCV_FILES


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _strip_sql_line_comments(sql: str) -> str:
    return re.sub(r"--[^\n]*", "", sql)


def _strip_all_sql_comments(sql: str) -> str:
    without_block = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    return _strip_sql_line_comments(without_block)


def _iter_files(paths: Iterable[Path]) -> list[Path]:
    result = list(paths)
    assert result, "Expected at least one script file to inspect."
    return result


class TestRepositoryStructure:
    """Ensure all 4 DBA lab pillars and core artifacts exist."""

    @pytest.mark.parametrize(
        "rel_path",
        [
            "README.md",
            "docker-compose.yml",
            ".env.example",
            ".gitignore",
            "requirements.txt",
            "01-security/01_pdb_rbac_setup.sql",
            "01-security/02_safe_priv_mgmt_pkg.sql",
            "01-security/03_vpd_rls_shared_pool.sql",
            "01-security/04_unified_audit_fga.sql",
            "01-security/05_tde_wallet_reference.sql",
            "02-oltp-tuning/01_schema_normalized.sql",
            "02-oltp-tuning/02_booking_pkg.sql",
            "02-oltp-tuning/03_seed_synthetic_data.sql",
            "02-oltp-tuning/04_benchmark_xplan.sql",
            "03-backup-recovery-rman/rman_backup_full.rcv",
            "03-backup-recovery-rman/rman_backup_inc1.rcv",
            "03-backup-recovery-rman/run_rman_backup.sh",
            "03-backup-recovery-rman/DR_PITR_RUNBOOK.md",
            "04-diagnostics/01_top_sql_and_waits.sql",
            "04-diagnostics/02_blocking_tree_and_locks.sql",
            "04-diagnostics/03_tablespace_fra_capacity.sql",
            "04-diagnostics/04_invalid_objects_stale_stats.sql",
        ],
    )
    def test_expected_file_exists(self, rel_path: str) -> None:
        target = REPO_ROOT / rel_path
        assert target.is_file(), f"Missing expected repository file: {rel_path}"
        assert target.stat().st_size > 0, f"Repository file is empty: {rel_path}"

    def test_shell_scripts_use_pure_lf_line_endings(self) -> None:
        """All .sh files must use pure Unix LF (no CRLF) to run in Linux containers."""
        offenders: list[str] = []
        for path in _iter_files(SHELL_FILES):
            raw_bytes = path.read_bytes()
            if b"\r" in raw_bytes:
                offenders.append(str(path.relative_to(REPO_ROOT)))
        assert not offenders, f"CRLF / CR line endings detected in shell scripts: {offenders}"


class TestSecurityHygiene:
    """Enforce zero Oracle anti-patterns and zero hardcoded credentials."""

    def test_zero_oracle_script_usage(self) -> None:
        offenders: list[str] = []
        pattern = re.compile(r"_ORACLE_SCRIPT", re.IGNORECASE)
        for path in _iter_files(ALL_SCRIPT_FILES):
            if pattern.search(_read_text(path)):
                offenders.append(str(path.relative_to(REPO_ROOT)))
        assert not offenders, f"Forbidden _ORACLE_SCRIPT found in: {offenders}"

    def test_zero_grant_all_privileges(self) -> None:
        offenders: list[str] = []
        pattern = re.compile(r"\bGRANT\s+ALL\s+PRIVILEGES\b", re.IGNORECASE)
        for path in _iter_files(ALL_SCRIPT_FILES):
            if pattern.search(_read_text(path)):
                offenders.append(str(path.relative_to(REPO_ROOT)))
        assert not offenders, f"Forbidden GRANT ALL PRIVILEGES found in: {offenders}"

    def test_zero_hardcoded_identified_by_passwords_in_sql(self) -> None:
        """Every IDENTIFIED BY clause in SQL must use a &SUBSTITUTION placeholder."""
        pattern = re.compile(r"\bIDENTIFIED\s+BY\s+([^\s;,]+)", re.IGNORECASE)
        offenders: list[tuple[str, str]] = []
        for path in _iter_files(SQL_FILES):
            for match in pattern.finditer(_read_text(path)):
                raw_token = match.group(1).strip().strip('"').strip("'")
                if not raw_token.startswith("&"):
                    offenders.append((str(path.relative_to(REPO_ROOT)), match.group(0)))
        assert not offenders, (
            "Hardcoded password detected in IDENTIFIED BY clause (must use &VAR): "
            f"{offenders}"
        )

    def test_zero_inline_sys_passwords_in_shell_and_rman(self) -> None:
        """Shell and RMAN scripts must use OS auth ('/'), never inline sys/password."""
        pattern = re.compile(
            r"\b(sys|system|pdbadmin)\s*/\s*[^\s@\"']+",
            re.IGNORECASE,
        )
        offenders: list[tuple[str, str]] = []
        for path in _iter_files(SHELL_FILES + RCV_FILES):
            for match in pattern.finditer(_read_text(path)):
                offenders.append((str(path.relative_to(REPO_ROOT)), match.group(0)))
        assert not offenders, f"Inline credential pattern found: {offenders}"


class TestOracleInternalsGuards:
    """Guard against subtle Oracle 19c/23ai runtime bugs and performance pitfalls."""

    def test_zero_large_single_level_connect_by_ora30009(self) -> None:
        """Single-level CONNECT BY LEVEL <= N with N > 10,000 risks ORA-30009 on 2 GB RAM."""
        pattern = re.compile(
            r"\bCONNECT\s+BY\s+(?:NOCYCLE\s+)?(?:LEVEL|ROWNUM)\s*<=\s*(\d+)",
            re.IGNORECASE,
        )
        offenders: list[tuple[str, int]] = []
        for path in _iter_files(SQL_FILES):
            code = _strip_sql_line_comments(_read_text(path))
            for match in pattern.finditer(code):
                limit = int(match.group(1))
                if limit > 10_000:
                    offenders.append((str(path.relative_to(REPO_ROOT)), limit))
        assert not offenders, (
            "Single-level CONNECT BY exceeds 10,000 rows (risks ORA-30009; use CROSS JOIN): "
            f"{offenders}"
        )

    def test_vpd_static_policy_has_zero_plsql_user_branching(self) -> None:
        """If DBMS_RLS.STATIC is used, the policy function must be 100% branch-free."""
        content = _read_text(REPO_ROOT / "01-security/03_vpd_rls_shared_pool.sql")
        code = _strip_sql_line_comments(content)
        assert "DBMS_RLS.STATIC" in code

        fn_match = re.search(
            r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+sec_admin\.fn_vpd_owner_scope\b(.*?)END\s+fn_vpd_owner_scope\s*;",
            code,
            re.IGNORECASE | re.DOTALL,
        )
        assert fn_match is not None, "Could not locate fn_vpd_owner_scope definition."
        fn_body = fn_match.group(1)

        assert not re.search(r"\b(IF|CASE)\b", fn_body, re.IGNORECASE), (
            "DBMS_RLS.STATIC policy function must NOT contain PL/SQL IF/CASE branching "
            "(Oracle caches the first caller's branch globally across sessions!)."
        )
        assert not re.search(r"\|\|\s*USER\b", fn_body, re.IGNORECASE), (
            "VPD policy function must not concatenate USER literal (causes Shared Pool storm)."
        )
        assert "SYS_CONTEXT('USERENV', 'SESSION_USER')" in fn_body
        assert "SYS_CONTEXT('CTX_HOTEL_SEC', 'IS_PRIVILEGED_REVIEWER')" in fn_body

    def test_vpd_definer_context_pkg_does_not_use_disabled_session_roles(self) -> None:
        """AUTHID DEFINER package / AFTER LOGON trigger disables roles, so avoid SYS_SESSION_ROLES there."""
        content = _read_text(REPO_ROOT / "01-security/03_vpd_rls_shared_pool.sql")
        code = _strip_sql_line_comments(content)
        pkg_match = re.search(
            r"CREATE\s+OR\s+REPLACE\s+PACKAGE\s+BODY\s+sec_admin\.pkg_sec_context\b(.*?)END\s+pkg_sec_context\s*;",
            code,
            re.IGNORECASE | re.DOTALL,
        )
        assert pkg_match is not None
        pkg_body = pkg_match.group(1)
        assert "SYS_SESSION_ROLES" not in pkg_body.upper(), (
            "SYS_SESSION_ROLES always returns 'FALSE' inside AUTHID DEFINER / AFTER LOGON triggers!"
        )
        assert "dba_role_privs" in pkg_body.lower()
        assert re.search(r"AFTER\s+LOGON\s+ON\s+DATABASE", code, re.IGNORECASE)
        assert "v$vpd_policy" in code.lower()
        assert "row_level_sec_mismatch" in code.lower()

    def test_autonomous_transactions_always_handle_rollback(self) -> None:
        """Every SQL script using PRAGMA AUTONOMOUS_TRANSACTION must include COMMIT and ROLLBACK."""
        offenders: list[str] = []
        for path in _iter_files(SQL_FILES):
            code = _strip_sql_line_comments(_read_text(path))
            if re.search(r"\bPRAGMA\s+AUTONOMOUS_TRANSACTION\b", code, re.IGNORECASE):
                has_commit = re.search(r"\bCOMMIT\s*;", code, re.IGNORECASE) is not None
                has_rollback = re.search(r"\bROLLBACK\s*;", code, re.IGNORECASE) is not None
                if not (has_commit and has_rollback):
                    offenders.append(str(path.relative_to(REPO_ROOT)))
        assert not offenders, (
            "PRAGMA AUTONOMOUS_TRANSACTION without both COMMIT and ROLLBACK risks ORA-06519: "
            f"{offenders}"
        )

    def test_benchmark_disables_serveroutput_before_display_cursor(self) -> None:
        """SET SERVEROUTPUT OFF must be active whenever DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, ...) runs."""
        content = _read_text(REPO_ROOT / "02-oltp-tuning/04_benchmark_xplan.sql")
        serveroutput_on: bool | None = None
        display_cursor_calls = 0

        for line_no, raw_line in enumerate(content.splitlines(), start=1):
            stripped = raw_line.strip()
            if stripped.startswith("--"):
                continue
            if re.match(r"^SET\s+SERVEROUTPUT\s+ON\b", stripped, re.IGNORECASE):
                serveroutput_on = True
            elif re.match(r"^SET\s+SERVEROUTPUT\s+OFF\b", stripped, re.IGNORECASE):
                serveroutput_on = False
            elif re.search(r"DBMS_XPLAN\.DISPLAY_CURSOR\s*\(\s*NULL\s*,\s*NULL", stripped, re.IGNORECASE):
                display_cursor_calls += 1
                assert serveroutput_on is False, (
                    f"Line {line_no}: DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, ...) called while "
                    "SERVEROUTPUT is not explicitly OFF (causes DBMS_OUTPUT.GET_LINES to hijack PREV_SQL_ID)."
                )

        assert display_cursor_calls >= 5, f"Expected at least 5 DISPLAY_CURSOR calls, found {display_cursor_calls}"


class TestRequiredOraclePrimitives:
    """Verify mandatory enterprise DBA primitives exist in their target scripts."""

    def test_pdb_rbac_uses_multitenant_container_switch_and_resource_limit(self) -> None:
        content = _read_text(REPO_ROOT / "01-security/01_pdb_rbac_setup.sql")
        assert re.search(
            r"ALTER\s+SESSION\s+SET\s+CONTAINER\s*=\s*FREEPDB1\s*;",
            content,
            re.IGNORECASE,
        )
        assert re.search(r"ALTER\s+SYSTEM\s+SET\s+RESOURCE_LIMIT\s*=\s*TRUE", content, re.IGNORECASE)
        assert "GRANT SELECT ON SYS.DBA_ROLE_PRIVS" in content

    def test_safe_priv_mgmt_uses_dbms_assert_and_qualified_split(self) -> None:
        content = _read_text(REPO_ROOT / "01-security/02_safe_priv_mgmt_pkg.sql")
        assert "DBMS_ASSERT.SIMPLE_SQL_NAME" in content
        assert "DBMS_ASSERT.QUALIFIED_SQL_NAME" in content
        assert "DBMS_ASSERT.SCHEMA_NAME" in content
        assert "DBMS_ASSERT.ENQUOTE_NAME" in content
        assert "DBMS_ASSERT.INVALID_SQL_NAME" in content
        assert "DBMS_ASSERT.INVALID_SCHEMA_NAME" in content
        assert "AUTHID CURRENT_USER" in content
        assert "grant_qualified_object_priv" in content
        assert "'PUBLIC'" in content

    def test_vpd_uses_sys_context_for_cursor_sharing(self) -> None:
        content = _read_text(REPO_ROOT / "01-security/03_vpd_rls_shared_pool.sql")
        assert "SYS_CONTEXT('USERENV', 'SESSION_USER')" in content
        assert "DBMS_RLS.ADD_POLICY" in content
        assert "v$sql" in content.lower()

    def test_audit_script_uses_fga_and_multitenant_dbms_audit_mgmt(self) -> None:
        content = _read_text(REPO_ROOT / "01-security/04_unified_audit_fga.sql")
        assert "CREATE AUDIT POLICY" in content
        assert "DBMS_FGA.ADD_POLICY" in content
        assert "SYS_CONTEXT('SYS_SESSION_ROLES', 'ROLE_HR_PAYROLL_ADMIN') = 'FALSE'" in content
        assert "AUTHID CURRENT_USER" in content
        assert "SYS_EXTRACT_UTC" in content
        assert "DBMS_AUDIT_MGMT.CONTAINER_CURRENT" in content
        assert "CLEAN_AUDIT_TRAIL" in content
        assert "CREATE_PURGE_JOB" in content
        assert "JOB_ADVANCE_AUDIT_WATERMARK" in content

    def test_tde_reference_uses_modern_wallet_root_licensing_and_con_id(self) -> None:
        content = _read_text(REPO_ROOT / "01-security/05_tde_wallet_reference.sql")
        assert "WALLET_ROOT" in content
        assert "TDE_CONFIGURATION" in content
        assert "ADMINISTER KEY MANAGEMENT" in content
        assert "&TDE_KEYSTORE_PWD" in content
        assert "Enterprise Edition" in content
        assert "Advanced Security Option" in content
        assert "ORA-00439" in content
        assert "t.con_id = e.con_id" in content

    def test_oltp_schema_uses_identity_keys_covering_and_fk_indexes(self) -> None:
        content = _read_text(REPO_ROOT / "02-oltp-tuning/01_schema_normalized.sql")
        assert "GENERATED BY DEFAULT AS IDENTITY" in content
        assert "NUMBER(12,2)" in content
        assert "idx_br_room_dates" in content
        assert "idx_bookings_customer_id" in content
        assert "chk_inv_total_math" in content

    def test_booking_pkg_uses_returning_multi_room_lock_order_and_ora30006(self) -> None:
        content = _read_text(REPO_ROOT / "02-oltp-tuning/02_booking_pkg.sql")
        assert "create_multi_room_booking" in content
        assert "INDEX BY PLS_INTEGER" in content
        assert "RETURNING booking_id INTO" in content
        assert re.search(r"FOR\s+UPDATE\s+OF\s+r\.room_id\s+WAIT\s+5", content, re.IGNORECASE)
        assert re.search(r"PRAGMA\s+EXCEPTION_INIT\s*\(\s*e_lock_timeout\s*,\s*-30006\s*\)", content, re.IGNORECASE)
        assert len(re.findall(r"\bWHEN\s+e_lock_timeout\b", content, re.IGNORECASE)) >= 4
        assert "br.check_in_date  < v_check_out" in content
        assert "br.check_out_date > v_check_in" in content
        assert "MERGE INTO hotel_app.invoices" in content

    def test_seed_script_uses_cross_join_and_gathers_optimizer_stats(self) -> None:
        content = _read_text(REPO_ROOT / "02-oltp-tuning/03_seed_synthetic_data.sql")
        assert "CONNECT BY LEVEL" in content
        assert "CROSS JOIN" in content
        assert "DBMS_RANDOM" in content
        assert "DBMS_STATS.GATHER_SCHEMA_STATS" in content
        assert "DBMS_STATS.AUTO_DEGREE" in content

    def test_benchmark_script_uses_dbms_xplan(self) -> None:
        content = _read_text(REPO_ROOT / "02-oltp-tuning/04_benchmark_xplan.sql")
        assert "GATHER_PLAN_STATISTICS" in content
        assert "DBMS_XPLAN.DISPLAY_CURSOR" in content
        assert "ALLSTATS LAST" in content

    def test_rman_scripts_and_runbook_cover_dr_primitives(self) -> None:
        full_rcv = _read_text(REPO_ROOT / "03-backup-recovery-rman/rman_backup_full.rcv")
        inc1_rcv = _read_text(REPO_ROOT / "03-backup-recovery-rman/rman_backup_inc1.rcv")
        wrapper = _read_text(REPO_ROOT / "03-backup-recovery-rman/run_rman_backup.sh")
        runbook = _read_text(REPO_ROOT / "03-backup-recovery-rman/DR_PITR_RUNBOOK.md")

        assert "INCREMENTAL LEVEL 0" in full_rcv
        assert "COMPRESSION ALGORITHM 'BASIC'" in full_rcv
        assert "CONTROLFILE AUTOBACKUP ON" in full_rcv
        assert "DELETE NOPROMPT OBSOLETE" in full_rcv
        assert "INCREMENTAL LEVEL 1" in inc1_rcv
        assert "set -euo pipefail" in wrapper
        assert "WHENEVER SQLERROR EXIT" in wrapper
        assert "ARCHIVELOG" in wrapper
        assert "ALTER PLUGGABLE DATABASE FREEPDB1 CLOSE IMMEDIATE;" in runbook
        assert "RESTORE PLUGGABLE DATABASE FREEPDB1;" in runbook
        assert "RECOVER PLUGGABLE DATABASE FREEPDB1" in runbook
        assert "ALTER PLUGGABLE DATABASE FREEPDB1 OPEN RESETLOGS;" in runbook
        assert "RECOVER TABLE HOTEL_APP.BOOKINGS OF PLUGGABLE DATABASE FREEPDB1" in runbook
        assert "AUXILIARY DESTINATION" in runbook
        assert "START WITH LIMIT VALUE" in runbook


class TestDiagnosticsKitReadOnlyAndPrimitives:
    """Validate Pillar 4 (04-diagnostics/) Day-2 DBA Triage Kit safety & internals."""

    EXPECTED_DIAGNOSTIC_FILES = (
        "04-diagnostics/01_top_sql_and_waits.sql",
        "04-diagnostics/02_blocking_tree_and_locks.sql",
        "04-diagnostics/03_tablespace_fra_capacity.sql",
        "04-diagnostics/04_invalid_objects_stale_stats.sql",
    )

    def test_all_four_diagnostic_scripts_present_and_pure_lf(self) -> None:
        assert len(DIAGNOSTIC_SQL_FILES) == 4, (
            f"Expected exactly 4 diagnostic scripts in 04-diagnostics/, found {len(DIAGNOSTIC_SQL_FILES)}"
        )
        offenders: list[str] = []
        for rel_path in self.EXPECTED_DIAGNOSTIC_FILES:
            path = REPO_ROOT / rel_path
            assert path.is_file(), f"Missing diagnostic script: {rel_path}"
            if b"\r" in path.read_bytes():
                offenders.append(rel_path)
        assert not offenders, f"CRLF / CR line endings detected in diagnostic scripts: {offenders}"

    @pytest.mark.parametrize("rel_path", EXPECTED_DIAGNOSTIC_FILES)
    def test_diagnostic_scripts_are_strictly_read_only_and_pdb_scoped(self, rel_path: str) -> None:
        """Every 04-diagnostics script must switch to FREEPDB1 and execute SELECT-only SQL."""
        content = _read_text(REPO_ROOT / rel_path)
        code = _strip_all_sql_comments(content)

        # Must explicitly switch into FREEPDB1
        assert re.search(
            r"ALTER\s+SESSION\s+SET\s+CONTAINER\s*=\s*FREEPDB1\s*;",
            code,
            re.IGNORECASE,
        ), f"{rel_path} must explicitly execute ALTER SESSION SET CONTAINER = FREEPDB1;"

        # Zero anti-patterns or hardcoded credentials
        assert not re.search(r"_ORACLE_SCRIPT", content, re.IGNORECASE)
        assert not re.search(r"\bGRANT\s+ALL\b", content, re.IGNORECASE)
        assert not re.search(r"\bIDENTIFIED\s+BY\b", code, re.IGNORECASE)

        # Strictly read-only: zero DML/DDL/ALTER TABLE/ALTER SYSTEM/dynamic SQL execution
        forbidden_dml_ddl = re.compile(
            r"\b(?:INSERT|UPDATE|DELETE|MERGE|DROP|TRUNCATE|CREATE|GRANT|REVOKE)\b"
            r"|\bALTER\s+(?:TABLE|SYSTEM|INDEX|USER|DATABASE|PLUGGABLE|TABLESPACE|PROFILE|ROLE)\b"
            r"|\bEXECUTE\s+IMMEDIATE\b",
            re.IGNORECASE,
        )
        matches = forbidden_dml_ddl.findall(code)
        assert not matches, (
            f"Read-only violation in {rel_path}: forbidden DDL/DML token(s) found: {matches}"
        )

    def test_top_sql_and_waits_primitives(self) -> None:
        content = _read_text(REPO_ROOT / "04-diagnostics/01_top_sql_and_waits.sql")
        lower = content.lower()
        assert "v$sql" in lower
        assert "elapsed_time" in lower
        assert "buffer_gets" in lower
        assert "v$system_event" in lower
        assert "wait_class" in lower
        assert "force_matching_signature" in lower
        assert re.search(r"COUNT\s*\(\s*\*\s*\)\s*>\s*5", content, re.IGNORECASE)
        assert re.search(r"COUNT\s*\(\s*DISTINCT\s+sql_id\s*\)\s*>\s*5", content, re.IGNORECASE)
        assert "v$pgastat" in lower
        assert "v$sga_dynamic_components" in lower
        assert "con_id" in lower

    def test_blocking_tree_and_locks_primitives(self) -> None:
        content = _read_text(REPO_ROOT / "04-diagnostics/02_blocking_tree_and_locks.sql")
        lower = content.lower()
        assert re.search(
            r"CONNECT\s+BY\s+NOCYCLE\s+PRIOR\s+sid\s*=\s*blocking_session",
            content,
            re.IGNORECASE,
        )
        assert re.search(r"blocking_session\s+IS\s+NULL", content, re.IGNORECASE)
        assert "v$session" in lower
        assert "v$sql" in lower
        assert "v$locked_object" in lower
        assert "dba_objects" in lower
        assert "locked_mode" in lower
        for mode_label in ("'NONE'", "'RS'", "'RX'", "'S'", "'SRX'", "'X'"):
            assert mode_label in content
        assert "v$transaction" in lower
        assert "used_ublk" in lower
        assert "used_urec" in lower
        assert "con_id" in lower

    def test_tablespace_fra_capacity_primitives(self) -> None:
        content = _read_text(REPO_ROOT / "04-diagnostics/03_tablespace_fra_capacity.sql")
        lower = content.lower()
        assert "dba_tablespace_usage_metrics" in lower
        assert "dba_tablespaces" in lower
        assert "used_percent" in lower
        assert "v$tempseg_usage" in lower
        assert "v$recovery_file_dest" in lower
        assert "v$flash_recovery_area_usage" in lower
        assert "ORA-19809" in content
        assert "v$log_history" in lower

    def test_invalid_objects_stale_stats_primitives(self) -> None:
        content = _read_text(REPO_ROOT / "04-diagnostics/04_invalid_objects_stale_stats.sql")
        lower = content.lower()
        assert "dba_objects" in lower
        assert "DBMS_UTILITY.COMPILE_SCHEMA" in content
        assert "dba_tab_statistics" in lower
        assert "stale_stats" in lower
        assert re.search(r"last_analyzed\s+IS\s+NULL", content, re.IGNORECASE)
        assert "dba_constraints" in lower
        assert "dba_indexes" in lower
        assert "dba_ind_partitions" in lower
        assert "UNUSABLE" in content
        assert "dba_segments" in lower
        assert "'HOTEL_APP'" in content
        assert "'SEC_ADMIN'" in content


class TestDockerComposeHygiene:
    """Validate docker-compose.yml uses Oracle 23ai Free and strict env substitution."""

    def test_docker_compose_image_and_env_substitution(self) -> None:
        compose_path = REPO_ROOT / "docker-compose.yml"
        data = yaml.safe_load(_read_text(compose_path))

        assert "services" in data and "oracle-lab-01" in data["services"]
        svc = data["services"]["oracle-lab-01"]

        assert svc["image"] == "gvenzl/oracle-free:23-slim-faststart"

        volumes = svc.get("volumes", [])
        assert "./04-diagnostics:/opt/lab/04-diagnostics:ro" in volumes, (
            "docker-compose.yml must mount ./04-diagnostics read-only into /opt/lab/04-diagnostics"
        )

        env = svc["environment"]
        assert isinstance(env, dict)
        for secret_key in ("ORACLE_PASSWORD", "APP_USER_PASSWORD"):
            assert secret_key in env, f"Missing {secret_key} in docker-compose.yml"
            val = str(env[secret_key])
            assert val.startswith("${") and val.endswith("}"), (
                f"{secret_key} must use ${{VAR}} env substitution, got: {val!r}"
            )

    def test_env_example_uses_safe_placeholders(self) -> None:
        env_example = _read_text(REPO_ROOT / ".env.example")
        for key in ("ORACLE_PASSWORD", "APP_USER_PASSWORD", "TDE_KEYSTORE_PWD"):
            match = re.search(rf"^{key}=(.+)$", env_example, re.MULTILINE)
            assert match is not None, f"{key} missing from .env.example"
            assert match.group(1).startswith("CHANGE_ME_"), (
                f"{key} in .env.example should use a CHANGE_ME_ placeholder."
            )
