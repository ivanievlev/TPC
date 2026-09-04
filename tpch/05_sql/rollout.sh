#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
source $PWD/../../parse_step_args.sh
source $PWD/../../mode.sh
init_tpc_mode

if [[ "$GEN_DATA_SCALE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "Missing required parameters from unified rollout."
	exit 1
fi
validate_skip_queries_list "$SKIP_QUERIES_LIST"

step=sql
init_log $step

echo "SQL_ON_ERROR_STOP = $SQL_ON_ERROR_STOP"
echo "STATEMENT_TIMEOUT = $STATEMENT_TIMEOUT"
echo "SINGLE_USER_ITERATIONS = $SINGLE_USER_ITERATIONS"
echo "SINGLE_EXPLAIN_ANALYZE_MODE = $SINGLE_EXPLAIN_ANALYZE_MODE"
echo "DROP_CACHE_BEFORE_SQL = $DROP_CACHE_BEFORE_SQL"
echo "RUN_SQL_WITH_DUCKDB = $RUN_SQL_WITH_DUCKDB"
echo "SKIP_QUERIES_LIST = $SKIP_QUERIES_LIST"
if [ "$SQL_ON_ERROR_STOP" == "true" ]; then
	ON_ERROR_STOP=1
else
	ON_ERROR_STOP=0
fi

PSQL_SESSION_SETS="SET statement_timeout='$STATEMENT_TIMEOUT';"
if [ "$RUN_SQL_WITH_DUCKDB" == "true" ]; then
	append_duckdb_session_sets
fi

mkdir -p $PWD/../../log/single_explain_analyze_log
rm -f $PWD/../../log/single_explain_analyze_log/*single.explain_analyze*.log
sql_file_list=""
for i in $(ls $PWD/*.tpch.*.sql); do
	qnum=$(echo "$i" | awk -F '.' '{print $3}')
	if should_skip_tpcds_query "$qnum"; then
		echo "Skipping $qnum due to $(_tpc_skip_list_var_name)=${SKIP_QUERIES_LIST}."
		continue
	fi
	sql_file_list="$sql_file_list $i"
done

nfiles=0
for _qf in $sql_file_list; do
	nfiles=$((nfiles + 1))
done
init_query_run_progress $((SINGLE_USER_ITERATIONS * nfiles))

for x in $(seq 1 $SINGLE_USER_ITERATIONS); do
	echo "SQL iteration $x of $SINGLE_USER_ITERATIONS"
	drop_os_page_cache_before_sql_iteration "$x" || exit 1
	for i in $sql_file_list; do
		id=$(echo $i | awk -F '.' '{print $1}')
		schema_name=$(echo $i | awk -F '.' '{print $2}')
		# description = schema.query.iteration so SCORE can split 05_sql passes
		table_name="$(echo $i | awk -F '.' '{print $3}').${x}"
		run_05_sql_query_file
	done
done

end_step $step
