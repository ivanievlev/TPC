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
RUN_COMPILE_TPCDS="$5"
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
EXTRA_TPCDS_SCHEMAS="${18}"
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
DROP_CACHE_BEFORE_EACH_SINGLE_QUERY="${31}"
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
SKIP_QUERIES_LIST="${49}"
TPC_MODE="${50:-TPC-DS}"

init_tpc_mode

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$RUN_COMPILE_TPCDS" == "" || "$RUN_GEN_DATA" == "" || "$RUN_INIT" == "" || "$RUN_DDL" == "" || "$RUN_LOAD" == "" || "$RUN_SQL" == "" || "$RUN_SINGLE_USER_REPORT" == "" || "$RUN_MULTI_USER" == "" || "$RUN_MULTI_USER_REPORT" == "" || "$RUN_SCORE" == "" || "$SINGLE_USER_ITERATIONS" == "" || "$DBNAME" == "" ]]; then
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
if [ -z "${SKIP_QUERIES_LIST+x}" ]; then
	SKIP_QUERIES_LIST=""
fi
validate_skip_queries_list "$SKIP_QUERIES_LIST"

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
	echo "Checking pg_duckdb extension (RUN_SQL_WITH_DUCKDB=true)..."
	if ! command -v psql >/dev/null 2>&1; then
		echo "ERROR: psql not found in PATH; cannot verify pg_duckdb extension."
		exit 1
	fi
	duckdb_available=$(psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -t -A -c "SELECT count(*) FROM pg_available_extensions WHERE name = 'pg_duckdb';" 2>/dev/null || echo "0")
	if [ "$duckdb_available" != "1" ]; then
		echo "ERROR: RUN_SQL_WITH_DUCKDB=true but extension pg_duckdb is not available in database $DBNAME."
		exit 1
	fi
	if ! psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -c "CREATE EXTENSION IF NOT EXISTS pg_duckdb;"; then
		echo "ERROR: failed to CREATE EXTENSION pg_duckdb in database $DBNAME."
		exit 1
	fi
	echo "pg_duckdb extension is available and installed."
fi

create_directories()
{
	if [ ! -d $LOCAL_PWD/log ]; then
		echo "Creating log directory"
		mkdir $LOCAL_PWD/log
	fi
}

create_directories
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
echo "RUN_COMPILE_TPCDS: $RUN_COMPILE_TPCDS  (compile step for current TPC_MODE)"
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
echo "EXTRA_TPCDS_SCHEMAS: $EXTRA_TPCDS_SCHEMAS"
echo "TRUNCATE_BEFORE_LOAD: $TRUNCATE_BEFORE_LOAD"
echo "SQL_ON_ERROR_STOP: $SQL_ON_ERROR_STOP"
echo "STATEMENT_TIMEOUT: $STATEMENT_TIMEOUT"
echo "ADMIN_USER: $ADMIN_USER"
echo "DBNAME: $DBNAME"
echo "USE_EXTERNAL_FORMAT: $USE_EXTERNAL_FORMAT"
echo "RUN_SQL_WITH_DUCKDB: $RUN_SQL_WITH_DUCKDB"
echo "############################################################################"
echo ""

# RUN_COMPILE_TPCDS gates the compile step for either mode (name kept for compatibility).
if [ "$RUN_COMPILE_TPCDS" == "true" ]; then
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
if [ "$RUN_SCORE" == "true" ]; then
	rm -f $PWD/log/end_score.log
fi

step_run_flag()
{
	local base
	base=$(basename "$1")
	case "$base" in
		00_compile_tpcds|00_compile_tpch) echo "$RUN_COMPILE_TPCDS" ;;
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

STEP_ARGS="$GEN_DATA_SCALE $EXPLAIN_ANALYZE $RANDOM_DISTRIBUTION $MULTI_USER_COUNT $SINGLE_USER_ITERATIONS $PARTITION_EVERY_FACTOR $EXCLUDE_HEAVY_QUERIES $EXTRA_TPCDS_SCHEMAS $TRUNCATE_BEFORE_LOAD $SQL_ON_ERROR_STOP $net_core_rmem $net_core_wmem $rg6_memory_limit $rg6_memory_shared_quota $rg6_concurrency $rg6_cpu_rate_limit $rg7_cpu_hard_quota_limit $DELETE_DAT_FILES_BEFORE_SQL $RUN_SQL_FROM_ROLE $DROP_CACHE_BEFORE_EACH_SINGLE_QUERY $HEAP_ONLY $ADMIN_USER $MAKE_PREREQUISITES $NETWORK_INTERFACE_JUMBOFRAME $SET_ORCA_OPTIMIZER $REFERENCE_TABLE_TYPE $DBNAME $STATEMENT_TIMEOUT $USE_EXTERNAL_FORMAT $EXTERNAL_HIVE_PARTITIONING $EXTERNAL_FILE_SIZE_BYTES $EXTERNAL_COMPRESSION $RUN_SQL_WITH_DUCKDB $PURGE_OLD_EXTERNAL_DATA $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN"

while IFS= read -r i; do
	[ -z "$i" ] && continue
	[ -d "$i" ] || continue
	run_flag=$(step_run_flag "$i")
	if [ "$run_flag" != "true" ]; then
		echo "Skipping $i (corresponding RUN_*=false)"
		continue
	fi
	echo "$i/rollout.sh"
	$i/rollout.sh $STEP_ARGS "$SKIP_QUERIES_LIST"
done < <(tpc_step_dirs "$PWD")
