#!/bin/bash
# Derive benchmark identity from TPC_MODE (default TPC-DS).
# Sourced by rollout.sh / entry scripts after variables are loaded.

init_tpc_mode()
{
	local mode="${TPC_MODE:-TPC-DS}"
	# Normalize aliases
	case "$(echo "$mode" | tr '[:lower:]' '[:upper:]' | tr -d ' ')" in
		TPC-DS|TPCDS|DS) mode="TPC-DS" ;;
		TPC-H|TPCH|H) mode="TPC-H" ;;
		*)
			echo "ERROR: TPC_MODE must be \"TPC-DS\" or \"TPC-H\" (got: ${TPC_MODE})"
			exit 1
			;;
	esac
	TPC_MODE="$mode"

	case "$TPC_MODE" in
		TPC-DS)
			TPC_BENCH_LABEL="TPC-DS"
			TPC_SCHEMA="tpcds"
			TPC_REPORT_SCHEMA="tpcds_reports"
			TPC_TESTING_SCHEMA="tpcds_testing"
			TPC_QUERY_ID_MAX=99
			TPC_COMPILE_STEP_NAME="compile_tpcds"
			TPC_ENTRY_SCRIPT="tpc.sh"
			TPC_LOG_PREFIX="tpcds"
			TPC_DATA_PREFIX="tpcds"
			TPC_STEP_ROOT="tpcds"   # relative to repo root; resolved by rollout
			;;
		TPC-H)
			TPC_BENCH_LABEL="TPC-H"
			TPC_SCHEMA="tpch"
			TPC_REPORT_SCHEMA="tpch_reports"
			TPC_TESTING_SCHEMA="tpch_testing"
			TPC_QUERY_ID_MAX=22
			TPC_COMPILE_STEP_NAME="compile_tpch"
			TPC_ENTRY_SCRIPT="tpc.sh"
			TPC_LOG_PREFIX="tpch"
			TPC_DATA_PREFIX="tpch"
			TPC_STEP_ROOT="tpch"
			;;
	esac

	export TPC_MODE TPC_BENCH_LABEL TPC_SCHEMA TPC_REPORT_SCHEMA TPC_TESTING_SCHEMA
	export TPC_QUERY_ID_MAX TPC_COMPILE_STEP_NAME TPC_ENTRY_SCRIPT TPC_LOG_PREFIX TPC_DATA_PREFIX TPC_STEP_ROOT

	if type resolve_tpc_skip_queries_list >/dev/null 2>&1; then
		resolve_tpc_skip_queries_list
	else
		case "$TPC_MODE" in
			TPC-H) SKIP_QUERIES_LIST="${SKIP_TPCH_QUERIES_LIST:-}" ;;
			*) SKIP_QUERIES_LIST="${SKIP_TPCDS_QUERIES_LIST:-}" ;;
		esac
		export SKIP_QUERIES_LIST
	fi
}

# Print space-separated absolute step directories for the current mode (ordered).
tpc_step_dirs()
{
	local root="$1"
	if [ "$TPC_MODE" = "TPC-H" ]; then
		printf '%s\n' \
			"$root/tpch/00_compile_tpch" \
			"$root/tpch/01_gen_data" \
			"$root/tpch/02_init" \
			"$root/tpch/03_ddl" \
			"$root/tpch/04_load" \
			"$root/tpch/05_sql" \
			"$root/tpch/06_single_user_reports" \
			"$root/tpch/07_multi_user" \
			"$root/tpch/08_multi_user_reports" \
			"$root/tpch/09_score"
	else
		printf '%s\n' \
			"$root/tpcds/00_compile_tpcds" \
			"$root/tpcds/01_gen_data" \
			"$root/tpcds/02_init" \
			"$root/tpcds/03_ddl" \
			"$root/tpcds/04_load" \
			"$root/tpcds/05_sql" \
			"$root/tpcds/06_single_user_reports" \
			"$root/tpcds/07_multi_user" \
			"$root/tpcds/08_multi_user_reports" \
			"$root/tpcds/09_score"
	fi
}
