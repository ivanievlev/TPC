#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
source $PWD/../../parse_step_args.sh
source $PWD/../../mode.sh
init_tpc_mode

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "Missing required parameters from unified rollout."
	exit 1
fi
validate_skip_queries_list "$SKIP_QUERIES_LIST"

step=sql
init_log $step

echo "SQL_ON_ERROR_STOP = $SQL_ON_ERROR_STOP"
echo "STATEMENT_TIMEOUT = $STATEMENT_TIMEOUT"
echo "SINGLE_USER_ITERATIONS = $SINGLE_USER_ITERATIONS"
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
	PSQL_SESSION_SETS="$PSQL_SESSION_SETS SET duckdb.force_execution TO true;"
	PSQL_SESSION_SETS="$PSQL_SESSION_SETS SET duckdb.memory_limit TO '$DUCKDB_MEMORY_LIMIT';"
	PSQL_SESSION_SETS="$PSQL_SESSION_SETS SET duckdb.threads TO $DUCKDB_THREADS;"
	PSQL_SESSION_SETS="$PSQL_SESSION_SETS SET duckdb.max_workers_per_postgres_scan TO $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN;"
	PSQL_SESSION_SETS="$PSQL_SESSION_SETS SET duckdb.threads_for_postgres_scan TO $DUCKDB_THREADS_FOR_POSTGRES_SCAN;"
fi

mkdir -p $PWD/../../log/single_explain_analyze_log
rm -f $PWD/../../log/single_explain_analyze_log/*single.explain_analyze*.log
sql_file_list=""
for i in $(ls $PWD/*.tpch.*.sql); do
	qnum=$(echo "$i" | awk -F '.' '{print $3}')
	if should_skip_tpcds_query "$qnum"; then
		echo "Skipping $qnum due to SKIP_QUERIES_LIST=${SKIP_QUERIES_LIST}."
		continue
	fi
	sql_file_list="$sql_file_list $i"
done

for x in $(seq 1 $SINGLE_USER_ITERATIONS); do
	echo "SQL iteration $x of $SINGLE_USER_ITERATIONS"
	drop_os_page_cache_before_sql_iteration "$x" || exit 1
	for i in $sql_file_list; do
		id=$(echo $i | awk -F '.' '{print $1}')
		schema_name=$(echo $i | awk -F '.' '{print $2}')
		# description = schema.query.iteration so SCORE can split 05_sql passes
		table_name="$(echo $i | awk -F '.' '{print $3}').${x}"
		start_log
		sql_outfile=$(mktemp)
		sql_errfile=$(mktemp)
		hostfile=$(mktemp)
		psql_rc=0
		if [ "$EXPLAIN_ANALYZE" == "false" ]; then
			echo "psql -d $DBNAME -c \"$PSQL_SESSION_SETS\" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE=\"\" -f $i | wc -l"
			set +e
			psql_run_sql_capturing_host "$i" "$sql_outfile" "$sql_errfile" "$hostfile" ""
			psql_rc=$?
			set -e
			if [ -s "$sql_errfile" ]; then
				cat "$sql_errfile" >&2
			fi
			tuples=$(wc -l < "$sql_outfile" | tr -d ' ')
		else
			myfilename=$(basename $i)
			mylogfile=$PWD/../../log/single_explain_analyze_log/$myfilename.single.explain_analyze.log
			echo "psql -d $DBNAME -c \"$PSQL_SESSION_SETS\" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE=\"EXPLAIN ANALYZE\" -f $i > $mylogfile"
			set +e
			psql_run_sql_capturing_host "$i" "$mylogfile" "$sql_errfile" "$hostfile" "EXPLAIN ANALYZE"
			psql_rc=$?
			set -e
			if [ -s "$sql_errfile" ]; then
				cat "$sql_errfile" >&2
			fi
			tuples=$(tuples_from_explain_log "$mylogfile")
		fi
		QUERY_STATUS=$(sql_query_status "$sql_errfile" "$psql_rc")
		log $tuples
		unset QUERY_STATUS QUERY_BACKEND_HOST
		rm -f "$sql_outfile" "$sql_errfile" "$hostfile"
	done
done

end_step $step
