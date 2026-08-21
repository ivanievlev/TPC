#!/bin/bash

set -e
PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/functions.sh
source $PWD/mode.sh
source_bashrc

GEN_DATA_SCALE="$1"
EXPLAIN_ANALYZE="$2"
RANDOM_DISTRIBUTION="$3"
MULTI_USER_COUNT="$4"
RUN_COMPILE_TPC="$5"
RUN_GEN_DATA="$6"
RUN_INIT="$7"
RUN_DDL="$8"
RUN_LOAD="$9"
RUN_SQL="${10}"
RUN_SINGLE_USER_REPORT="${11}"
RUN_MULTI_USER="${12}"
RUN_MULTI_USER_REPORT="${13}"
RUN_SCORE="${14}"
SINGLE_USER_ITERATIONS="${15}"
PARTITION_EVERY_FACTOR="${16}"
EXCLUDE_HEAVY_QUERIES="${17}"
EMPTY_SCHEMAS_CNT="${18:-0}"
TRUNCATE_BEFORE_LOAD="${19}"
SQL_ON_ERROR_STOP="${20}"
net_core_rmem="${21}"
net_core_wmem="${22}"
rg6_memory_limit="${23}"
rg6_memory_shared_quota="${24}"
rg6_concurrency="${25}"
rg6_cpu_rate_limit="${26}"
rg7_cpu_hard_quota_limit="${27}"
DELETE_DAT_FILES_BEFORE_SQL="${28}"
RUN_SQL_FROM_ROLE="${29}"
REFERENCE_TABLE_TYPE="${30}"
DROP_CACHE_BEFORE_SQL="${31}"
HEAP_ONLY="${32}"
ADMIN_USER="${33}"
MAKE_PREREQUISITES="${34}"
NETWORK_INTERFACE_JUMBOFRAME="${35}"
SET_ORCA_OPTIMIZER="${36}"
DBNAME="${37}"
STATEMENT_TIMEOUT="${38}"
USE_EXTERNAL_FORMAT="${39}"
EXTERNAL_HIVE_PARTITIONING="${40}"
EXTERNAL_FILE_SIZE_BYTES="${41}"
EXTERNAL_COMPRESSION="${42}"
RUN_SQL_WITH_DUCKDB="${43}"
PURGE_OLD_EXTERNAL_DATA="${44}"
DUCKDB_MEMORY_LIMIT="${45}"
DUCKDB_THREADS="${46}"
DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN="${47}"
DUCKDB_THREADS_FOR_POSTGRES_SCAN="${48}"
COLLECT_OS_DATA="${49:-true}"
COLLECT_DATA_PERIOD="${50:-5s}"
SKIP_QUERIES_LIST="${51}"
TPC_MODE="${52:-TPC-DS}"
DAT_FILE_SUBDIRECTORY_NAME="${53:-${DAT_FILE_SUBDIRECTORY_NAME:-arenadata}}"
EXTERNAL_FILE_DIRECTORY_PATH="${54:-${EXTERNAL_FILE_DIRECTORY_PATH:-/tmp}}"
APPLY_PGCONFIG_PARAMETERS="${APPLY_PGCONFIG_PARAMETERS:-false}"

init_tpc_mode

if [ -z "$COLLECT_OS_DATA" ]; then
	COLLECT_OS_DATA="true"
fi
if [ -z "$COLLECT_DATA_PERIOD" ]; then
	COLLECT_DATA_PERIOD="5s"
fi
export COLLECT_OS_DATA COLLECT_DATA_PERIOD APPLY_PGCONFIG_PARAMETERS

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$RUN_COMPILE_TPC" == "" || "$RUN_GEN_DATA" == "" || "$RUN_INIT" == "" || "$RUN_DDL" == "" || "$RUN_LOAD" == "" || "$RUN_SQL" == "" || "$RUN_SINGLE_USER_REPORT" == "" || "$RUN_MULTI_USER" == "" || "$RUN_MULTI_USER_REPORT" == "" || "$RUN_SCORE" == "" || "$SINGLE_USER_ITERATIONS" == "" || "$DBNAME" == "" ]]; then
	echo "Please run this script from tpc.sh so the correct parameters are passed to it."
	exit 1
fi
if [ -z "$STATEMENT_TIMEOUT" ]; then
	STATEMENT_TIMEOUT="1h"
fi
if [ -z "$USE_EXTERNAL_FORMAT" ]; then
	USE_EXTERNAL_FORMAT="false"
fi
if [ -z "$EXTERNAL_HIVE_PARTITIONING" ]; then
	EXTERNAL_HIVE_PARTITIONING="false"
fi
if [ -z "$EXTERNAL_FILE_SIZE_BYTES" ]; then
	EXTERNAL_FILE_SIZE_BYTES="-1"
fi
if [ -z "$EXTERNAL_COMPRESSION" ]; then
	EXTERNAL_COMPRESSION="false"
fi
if [ -z "$RUN_SQL_WITH_DUCKDB" ]; then
	RUN_SQL_WITH_DUCKDB="false"
fi
if [ -z "$PURGE_OLD_EXTERNAL_DATA" ]; then
	PURGE_OLD_EXTERNAL_DATA="true"
fi
if [ -z "$DUCKDB_MEMORY_LIMIT" ]; then
	DUCKDB_MEMORY_LIMIT="4GB"
fi
if [ -z "$DUCKDB_THREADS" ]; then
	DUCKDB_THREADS="-1"
fi
if [ -z "$DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN" ]; then
	DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN="2"
fi
if [ -z "$DUCKDB_THREADS_FOR_POSTGRES_SCAN" ]; then
	DUCKDB_THREADS_FOR_POSTGRES_SCAN="2"
fi
if [ -z "$COLLECT_OS_DATA" ]; then
	COLLECT_OS_DATA="true"
fi
if [ -z "$COLLECT_DATA_PERIOD" ]; then
	COLLECT_DATA_PERIOD="5s"
fi
if [ -z "${SKIP_QUERIES_LIST+x}" ]; then
	SKIP_QUERIES_LIST=""
fi
validate_skip_queries_list "$SKIP_QUERIES_LIST"

if [ -z "$DAT_FILE_SUBDIRECTORY_NAME" ]; then
	DAT_FILE_SUBDIRECTORY_NAME="arenadata"
fi
normalize_dat_file_subdirectory_name
if [ -z "$EXTERNAL_FILE_DIRECTORY_PATH" ]; then
	EXTERNAL_FILE_DIRECTORY_PATH="/tmp"
fi
normalize_external_file_directory_path
export DAT_FILE_SUBDIRECTORY_NAME EXTERNAL_FILE_DIRECTORY_PATH

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
echo "EXPLAIN_ANALYZE: $EXPLAIN_ANALYZE"
echo "RANDOM_DISTRIBUTION: $RANDOM_DISTRIBUTION"
echo "MULTI_USER_COUNT: $MULTI_USER_COUNT"
echo "RUN_COMPILE_TPC: $RUN_COMPILE_TPC  (compile step for current TPC_MODE)"
echo "RUN_GEN_DATA: $RUN_GEN_DATA"
echo "RUN_INIT: $RUN_INIT"
echo "RUN_DDL: $RUN_DDL"
echo "RUN_LOAD: $RUN_LOAD"
echo "RUN_SQL: $RUN_SQL"
echo "SINGLE_USER_ITERATIONS: $SINGLE_USER_ITERATIONS"
echo "RUN_SINGLE_USER_REPORT: $RUN_SINGLE_USER_REPORT"
echo "RUN_MULTI_USER: $RUN_MULTI_USER"
echo "RUN_MULTI_USER_REPORT: $RUN_MULTI_USER_REPORT"
echo "RUN_SCORE: $RUN_SCORE"
echo "PARTITION_EVERY_FACTOR: $PARTITION_EVERY_FACTOR"
echo "EXCLUDE_HEAVY_QUERIES: $EXCLUDE_HEAVY_QUERIES"
echo "SKIP_QUERIES_LIST: $SKIP_QUERIES_LIST"
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
echo "DAT_FILE_SUBDIRECTORY_NAME: $DAT_FILE_SUBDIRECTORY_NAME"
echo "EXTERNAL_FILE_DIRECTORY_PATH: $EXTERNAL_FILE_DIRECTORY_PATH"
echo "USE_EXTERNAL_FORMAT: $USE_EXTERNAL_FORMAT"
echo "RUN_SQL_WITH_DUCKDB: $RUN_SQL_WITH_DUCKDB"
echo "############################################################################"
echo ""

# RUN_COMPILE_TPC gates the compile step for either mode (00_compile_tpcds / 00_compile_tpch).
if [ "$RUN_COMPILE_TPC" == "true" ]; then
	rm -f $PWD/log/end_compile_tpcds.log
	rm -f $PWD/log/end_compile_tpch.log
fi
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
if [ "$RUN_SQL" == "true" ]; then
	rm -f $PWD/log/end_sql.log
fi
if [ "$RUN_SINGLE_USER_REPORT" == "true" ]; then
	rm -f $PWD/log/end_single_user_reports.log
fi
if [ "$RUN_MULTI_USER" == "true" ]; then
	rm -f $PWD/log/end_testing_log/end_testing_*.log
fi
if [ "$RUN_MULTI_USER_REPORT" == "true" ]; then
	rm -f $PWD/log/end_multi_user_reports.log
fi

export RUN_MULTI_USER RUN_MULTI_USER_REPORT APPLY_PGCONFIG_PARAMETERS
if [ "$RUN_SCORE" == "true" ]; then
	rm -f $PWD/log/end_score.log
fi

step_run_flag()
{
	local base
	base=$(basename "$1")
	case "$base" in
		00_compile_tpcds|00_compile_tpch) echo "$RUN_COMPILE_TPC" ;;
		01_gen_data) echo "$RUN_GEN_DATA" ;;
		02_init) echo "$RUN_INIT" ;;
		03_ddl) echo "$RUN_DDL" ;;
		04_load) echo "$RUN_LOAD" ;;
		05_sql) echo "$RUN_SQL" ;;
		06_single_user_reports) echo "$RUN_SINGLE_USER_REPORT" ;;
		07_multi_user) echo "$RUN_MULTI_USER" ;;
		08_multi_user_reports) echo "$RUN_MULTI_USER_REPORT" ;;
		09_score) echo "$RUN_SCORE" ;;
		*) echo "true" ;;
	esac
}

STEP_ARGS="$GEN_DATA_SCALE $EXPLAIN_ANALYZE $RANDOM_DISTRIBUTION $MULTI_USER_COUNT $SINGLE_USER_ITERATIONS $PARTITION_EVERY_FACTOR $EXCLUDE_HEAVY_QUERIES $EMPTY_SCHEMAS_CNT $TRUNCATE_BEFORE_LOAD $SQL_ON_ERROR_STOP $net_core_rmem $net_core_wmem $rg6_memory_limit $rg6_memory_shared_quota $rg6_concurrency $rg6_cpu_rate_limit $rg7_cpu_hard_quota_limit $DELETE_DAT_FILES_BEFORE_SQL $RUN_SQL_FROM_ROLE $DROP_CACHE_BEFORE_SQL $HEAP_ONLY $ADMIN_USER $MAKE_PREREQUISITES $NETWORK_INTERFACE_JUMBOFRAME $SET_ORCA_OPTIMIZER $REFERENCE_TABLE_TYPE $DBNAME $STATEMENT_TIMEOUT $USE_EXTERNAL_FORMAT $EXTERNAL_HIVE_PARTITIONING $EXTERNAL_FILE_SIZE_BYTES $EXTERNAL_COMPRESSION $RUN_SQL_WITH_DUCKDB $PURGE_OLD_EXTERNAL_DATA $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN $COLLECT_OS_DATA $COLLECT_DATA_PERIOD"

while IFS= read -r i; do
	[ -z "$i" ] && continue
	[ -d "$i" ] || continue
	run_flag=$(step_run_flag "$i")
	if [ "$run_flag" != "true" ]; then
		echo "Skipping $i (corresponding RUN_*=false)"
		continue
	fi
	echo "$i/rollout.sh"
	# Close stdin so step scripts (ssh, tools, etc.) cannot consume the step list
	# from this while-read loop (classic bash pitfall).
	$i/rollout.sh $STEP_ARGS "$SKIP_QUERIES_LIST" "$DAT_FILE_SUBDIRECTORY_NAME" "$EXTERNAL_FILE_DIRECTORY_PATH" </dev/null
done < <(tpc_step_dirs "$PWD")
