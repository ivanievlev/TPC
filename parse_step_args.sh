#!/bin/bash
# Load knobs from tpc_variables.sh (harness root). Positional step arguments are not used.
# Source after: set -e; PWD=...; source functions.sh

_TPC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -f "$_TPC_ROOT/tpc_variables.sh" ]; then
	echo "ERROR: tpc_variables.sh not found in $_TPC_ROOT"
	exit 1
fi
if [ "${TPC_VARIABLES_LOADED:-}" != "1" ]; then
	# shellcheck disable=SC1091
	source "$_TPC_ROOT/tpc_variables.sh"
	# Do not export this flag: child step scripts must re-source tpc_variables.sh
	# (only exported variables are inherited, and knobs are not all exported).
	TPC_VARIABLES_LOADED=1
fi
unset _TPC_ROOT

REPO="TPC"

# Compatibility if an old environment still exports RUN_SQL.
if [ -z "${RUN_SINGLE_USER:-}" ] && [ -n "${RUN_SQL:-}" ]; then
	RUN_SINGLE_USER="$RUN_SQL"
fi
if [ -z "${SKIP_TPCDS_QUERIES_LIST+x}" ] && [ -n "${SKIP_QUERIES_LIST+x}" ]; then
	SKIP_TPCDS_QUERIES_LIST="$SKIP_QUERIES_LIST"
fi
if [ -z "${SKIP_TPCH_QUERIES_LIST+x}" ] && [ -n "${SKIP_QUERIES_LIST+x}" ]; then
	SKIP_TPCH_QUERIES_LIST="$SKIP_QUERIES_LIST"
fi

# Legacy alias used by tpcds/02_init
if [ -z "${SET_OPTIMIZER:-}" ] && [ -n "${SET_ORCA_OPTIMIZER:-}" ]; then
	SET_OPTIMIZER="$SET_ORCA_OPTIMIZER"
fi

# Legacy alias
if [ -z "$EMPTY_SCHEMAS_CNT" ] && [ -n "${EXTRA_TPCDS_SCHEMAS:-}" ]; then
	EMPTY_SCHEMAS_CNT="$EXTRA_TPCDS_SCHEMAS"
fi
if [ -z "$EMPTY_SCHEMAS_CNT" ]; then
	EMPTY_SCHEMAS_CNT="0"
fi
if [ -z "$DROP_CACHE_BEFORE_SQL" ]; then
	DROP_CACHE_BEFORE_SQL="false"
fi
if [ -z "$STATEMENT_TIMEOUT" ]; then
	STATEMENT_TIMEOUT="1h"
fi
if [ -z "$RUN_SQL_WITH_DUCKDB" ]; then
	RUN_SQL_WITH_DUCKDB="false"
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
if [ -z "${SKIP_TPCDS_QUERIES_LIST+x}" ]; then
	SKIP_TPCDS_QUERIES_LIST=""
fi
if [ -z "${SKIP_TPCH_QUERIES_LIST+x}" ]; then
	SKIP_TPCH_QUERIES_LIST=""
fi
if [ -z "$USE_EXTERNAL_FORMAT" ]; then
	USE_EXTERNAL_FORMAT="false"
fi
if [ -z "$TRUNCATE_BEFORE_LOAD" ]; then
	TRUNCATE_BEFORE_LOAD="true"
fi
if [ -z "$SQL_ON_ERROR_STOP" ]; then
	SQL_ON_ERROR_STOP="true"
fi
if [ -z "$APPLY_PGCONFIG_PARAMETERS" ]; then
	APPLY_PGCONFIG_PARAMETERS="false"
fi

if [ -z "${DAT_FILE_DIRECTORY_PATH:-}" ]; then
	DAT_FILE_DIRECTORY_PATH="/tmp"
fi
if type normalize_dat_file_directory_path >/dev/null 2>&1; then
	normalize_dat_file_directory_path
fi
if type normalize_external_file_directory_path >/dev/null 2>&1; then
	normalize_external_file_directory_path
fi

if type apply_tpc_pgport >/dev/null 2>&1; then
	if type set_tpc_pgport_for_step >/dev/null 2>&1; then
		set_tpc_pgport_for_step "$PWD"
	fi
	apply_tpc_pgport
else
	PGPORT="${PGPORT:-${PGPORT_WRITE:-5432}}"
	export PGPORT
	if [ -z "${PGHOST:-}" ]; then
		unset PGHOST
	else
		export PGHOST
	fi
fi

export REPO RUN_SINGLE_USER RUN_MULTI_USER SKIP_TPCDS_QUERIES_LIST SKIP_TPCH_QUERIES_LIST
export APPLY_PGCONFIG_PARAMETERS PGPORT_WRITE PGPORT_SELECT SET_OPTIMIZER SET_ORCA_OPTIMIZER
