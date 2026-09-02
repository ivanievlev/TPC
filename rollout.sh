#!/bin/bash

set -e
PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/functions.sh
source $PWD/parse_step_args.sh
source $PWD/mode.sh
source_bashrc
init_tpc_mode
apply_tpc_pgport

export COLLECT_OS_DATA COLLECT_DATA_PERIOD APPLY_PGCONFIG_PARAMETERS PGPORT_WRITE PGPORT_SELECT
if [ -z "${PGPORT:-}" ]; then
	PGPORT="${PGPORT_WRITE:-5432}"
fi
export PGPORT
if [ -n "${PGHOST:-}" ]; then
	export PGHOST
else
	unset PGHOST
fi

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$RUN_GEN_DATA" == "" || "$RUN_INIT" == "" || "$RUN_DDL" == "" || "$RUN_LOAD" == "" || "$RUN_SINGLE_USER" == "" || "$RUN_MULTI_USER" == "" || "$SINGLE_USER_ITERATIONS" == "" || "$DBNAME" == "" ]]; then
	echo "Please run this script from tpc.sh so tpc_variables.sh is complete."
	exit 1
fi
validate_skip_queries_list "$SKIP_QUERIES_LIST"

# Patroni: generation, DDL, COPY FROM, and reports must run on the leader so
# the Postgres backend sees files on this host (HAProxy 16432 would otherwise
# execute COPY on another node).
require_tpc_host_is_patroni_leader

export DAT_FILE_DIRECTORY_PATH EXTERNAL_FILE_DIRECTORY_PATH

hive_on=$(echo "${EXTERNAL_HIVE_PARTITIONING}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
case "$hive_on" in
	true|false) ;;
	*)
		echo "ERROR: EXTERNAL_HIVE_PARTITIONING must be \"true\" or \"false\" (got: $EXTERNAL_HIVE_PARTITIONING)"
		exit 1
		;;
esac
EXTERNAL_HIVE_PARTITIONING="$hive_on"

case "$USE_EXTERNAL_FORMAT" in
	false) ;;
	parquet|csv|json)
		if [ "$RUN_SQL_WITH_DUCKDB" != "true" ]; then
			echo "${USE_EXTERNAL_FORMAT} files can't be processed without DuckDB. Change format or activate DuckDB"
			exit 1
		fi
		if [ "$EXTERNAL_HIVE_PARTITIONING" = "true" ] && \
			[ "${EXTERNAL_FILE_SIZE_BYTES}" != "-1" ] && [ -n "${EXTERNAL_FILE_SIZE_BYTES}" ]; then
			echo "ERROR: EXTERNAL_HIVE_PARTITIONING=true and EXTERNAL_FILE_SIZE_BYTES (${EXTERNAL_FILE_SIZE_BYTES}) are incompatible."
			exit 1
		fi
		;;
	*)
		echo "ERROR: USE_EXTERNAL_FORMAT must be \"false\", \"parquet\", \"csv\" or \"json\" (got: $USE_EXTERNAL_FORMAT)"
		exit 1
		;;
esac

if [ "$RUN_SQL_WITH_DUCKDB" = "true" ]; then
	echo "Ensuring pg_duckdb extension (RUN_SQL_WITH_DUCKDB=true)..."
	if ! command -v psql >/dev/null 2>&1; then
		echo "ERROR: psql not found in PATH; cannot install/verify pg_duckdb."
		exit 1
	fi

	# Database must exist before CREATE EXTENSION (02_init may not have run yet).
	db_exists=$(psql -d postgres -v ON_ERROR_STOP=1 -q -t -A -c "SELECT count(*) FROM pg_database WHERE datname = '$DBNAME';" 2>/dev/null | tr -d '[:space:]')
	if [ "$db_exists" != "1" ]; then
		echo "Database $DBNAME does not exist yet; creating it for pg_duckdb..."
		psql -d postgres -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE $DBNAME;"
	fi

	ext_installed=$(psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -t -A -c "SELECT count(*) FROM pg_extension WHERE extname = 'pg_duckdb';" 2>/dev/null | tr -d '[:space:]')
	if [ "$ext_installed" = "1" ]; then
		echo "pg_duckdb is already installed in $DBNAME."
	else
		echo "pg_duckdb not installed in $DBNAME; running CREATE EXTENSION pg_duckdb..."
		if ! psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -c "CREATE EXTENSION IF NOT EXISTS pg_duckdb;"; then
			echo "ERROR: failed to CREATE EXTENSION pg_duckdb in database $DBNAME."
			echo "Install the pg_duckdb package/shared library on the server, then re-run."
			exit 1
		fi
		ext_installed=$(psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -t -A -c "SELECT count(*) FROM pg_extension WHERE extname = 'pg_duckdb';" 2>/dev/null | tr -d '[:space:]')
		if [ "$ext_installed" != "1" ]; then
			echo "ERROR: CREATE EXTENSION pg_duckdb reported success but extension is still missing in $DBNAME."
			exit 1
		fi
		echo "pg_duckdb extension created in $DBNAME."
	fi
fi

create_directories()
{
	if [ ! -d $LOCAL_PWD/log ]; then
		echo "Creating log directory"
		mkdir $LOCAL_PWD/log
	fi
}

create_directories

# Local OS metrics sampler (no Prometheus). Runs for the whole rollout when enabled.
# shellcheck source=score_helpers.sh
source "$PWD/score_helpers.sh"
if [ "$COLLECT_OS_DATA" = "true" ]; then
	start_os_metrics_collector || exit 1
	trap 'stop_os_metrics_collector' EXIT
fi

echo "############################################################################"
echo "${TPC_BENCH_LABEL} Script (unified TPC harness)."
echo "############################################################################"
echo ""
echo "############################################################################"
echo "TPC_MODE: $TPC_MODE"
echo "GEN_DATA_SCALE: $GEN_DATA_SCALE"
echo "EXPLAIN_ANALYZE: $EXPLAIN_ANALYZE  (05_sql only)"
echo "RANDOM_DISTRIBUTION: $RANDOM_DISTRIBUTION"
echo "MULTI_USER_COUNT: $MULTI_USER_COUNT"
echo "RUN_GEN_DATA: $RUN_GEN_DATA"
echo "RUN_INIT: $RUN_INIT"
echo "RUN_DDL: $RUN_DDL"
echo "RUN_LOAD: $RUN_LOAD"
echo "RUN_SINGLE_USER: $RUN_SINGLE_USER"
echo "SINGLE_USER_ITERATIONS: $SINGLE_USER_ITERATIONS"
echo "RUN_MULTI_USER: $RUN_MULTI_USER"
echo "PARTITION_EVERY_FACTOR: $PARTITION_EVERY_FACTOR"
echo "EXCLUDE_HEAVY_QUERIES: $EXCLUDE_HEAVY_QUERIES"
echo "SKIP_TPCDS_QUERIES_LIST: $SKIP_TPCDS_QUERIES_LIST"
echo "SKIP_TPCH_QUERIES_LIST: $SKIP_TPCH_QUERIES_LIST"
echo "SKIP_QUERIES_LIST (active): $SKIP_QUERIES_LIST"
echo "EMPTY_SCHEMAS_CNT: $EMPTY_SCHEMAS_CNT"
echo "COLLECT_OS_DATA: $COLLECT_OS_DATA"
echo "COLLECT_DATA_PERIOD: $COLLECT_DATA_PERIOD"
echo "APPLY_PGCONFIG_PARAMETERS: $APPLY_PGCONFIG_PARAMETERS"
echo "TRUNCATE_BEFORE_LOAD: $TRUNCATE_BEFORE_LOAD"
echo "DROP_CACHE_BEFORE_SQL: $DROP_CACHE_BEFORE_SQL"
echo "SQL_ON_ERROR_STOP: $SQL_ON_ERROR_STOP"
echo "STATEMENT_TIMEOUT: $STATEMENT_TIMEOUT"
echo "ADMIN_USER: $ADMIN_USER"
echo "DBNAME: $DBNAME"
echo "PGPORT_WRITE: $PGPORT_WRITE"
echo "PGPORT_SELECT: $PGPORT_SELECT"
echo "PGHOST: ${PGHOST:-}"
echo "DAT_FILE_DIRECTORY_PATH: $DAT_FILE_DIRECTORY_PATH"
echo "EXTERNAL_FILE_DIRECTORY_PATH: $EXTERNAL_FILE_DIRECTORY_PATH"
echo "USE_EXTERNAL_FORMAT: $USE_EXTERNAL_FORMAT"
echo "RUN_SQL_WITH_DUCKDB: $RUN_SQL_WITH_DUCKDB"
echo "############################################################################"
echo ""

# Compile (00_compile_tpcds / 00_compile_tpch) always runs so dsdgen/qgen stay present.
rm -f $PWD/log/end_compile_tpcds.log
rm -f $PWD/log/end_compile_tpch.log
if [ "$RUN_GEN_DATA" == "true" ]; then
	rm -f $PWD/log/end_gen_data.log
fi
if [ "$RUN_INIT" == "true" ]; then
	rm -f $PWD/log/end_init.log
fi
if [ "$RUN_DDL" == "true" ]; then
	rm -f $PWD/log/end_ddl.log
fi
if [ "$RUN_LOAD" == "true" ]; then
	rm -f $PWD/log/end_load.log
fi
if [ "$RUN_SINGLE_USER" == "true" ]; then
	rm -f $PWD/log/end_sql.log
	rm -f $PWD/log/end_single_user_reports.log
fi
if [ "$RUN_MULTI_USER" == "true" ]; then
	rm -f $PWD/log/end_testing_log/end_testing_*.log
	rm -f $PWD/log/end_multi_user_reports.log
fi

export RUN_MULTI_USER APPLY_PGCONFIG_PARAMETERS
rm -f $PWD/log/end_score.log
rm -f $PWD/log/tpc_stopped_on_error

step_run_flag()
{
	local base
	base=$(basename "$1")
	case "$base" in
		00_compile_tpcds|00_compile_tpch) echo "true" ;;
		01_gen_data) echo "$RUN_GEN_DATA" ;;
		02_init) echo "$RUN_INIT" ;;
		03_ddl) echo "$RUN_DDL" ;;
		04_load) echo "$RUN_LOAD" ;;
		05_sql) echo "$RUN_SINGLE_USER" ;;
		06_single_user_reports) echo "$RUN_SINGLE_USER" ;;
		07_multi_user) echo "$RUN_MULTI_USER" ;;
		08_multi_user_reports) echo "$RUN_MULTI_USER" ;;
		09_score) echo "true" ;;
		*) echo "true" ;;
	esac
}

TPC_STOPPED_ON_ERROR=""

while IFS= read -r i; do
	[ -z "$i" ] && continue
	[ -d "$i" ] || continue
	base=$(basename "$i")
	run_flag=$(step_run_flag "$i")
	if [ "$run_flag" != "true" ]; then
		echo "Skipping $i (corresponding RUN_*=false)"
		continue
	fi
	if [ -n "$TPC_STOPPED_ON_ERROR" ] && [ "$base" != "09_score" ]; then
		echo "Skipping $i (SQL_ON_ERROR_STOP: $TPC_STOPPED_ON_ERROR STOPPED ON ERROR)"
		continue
	fi
	echo "$i/rollout.sh"
	set_tpc_pgport_for_step "$i"
	echo "  PGPORT=$PGPORT (WRITE=$PGPORT_WRITE SELECT=$PGPORT_SELECT)"
	# Close stdin so step scripts (ssh, tools, etc.) cannot consume the step list
	# from this while-read loop (classic bash pitfall).
	if "$i/rollout.sh" </dev/null; then
		:
	else
		rc=$?
		echo "WARNING: $i/rollout.sh exited $rc"
		if [ "${SQL_ON_ERROR_STOP:-false}" = "true" ] && { [ "$base" = "05_sql" ] || [ "$base" = "07_multi_user" ]; }; then
			TPC_STOPPED_ON_ERROR="$base"
			{
				echo "step=$base"
				echo "exit_code=$rc"
			} > "$PWD/log/tpc_stopped_on_error"
			echo "SQL_ON_ERROR_STOP=true: $base STOPPED ON ERROR (no end_*.log). Remaining steps skipped except SCORE."
			continue
		fi
		exit "$rc"
	fi
done < <(tpc_step_dirs "$PWD")

if [ -n "$TPC_STOPPED_ON_ERROR" ]; then
	echo "Rollout stopped on error in $TPC_STOPPED_ON_ERROR; SCORE used successfully completed steps only."
	exit 1
fi
