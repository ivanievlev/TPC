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
for i in $(ls $PWD/*.tpch.*.sql); do
	qnum=$(echo "$i" | awk -F '.' '{print $3}')
	if should_skip_tpcds_query "$qnum"; then
		echo "Skipping $qnum due to SKIP_QUERIES_LIST=${SKIP_QUERIES_LIST}."
		continue
	fi
	for x in $(seq 1 $SINGLE_USER_ITERATIONS); do
		id=$(echo $i | awk -F '.' '{print $1}')
		schema_name=$(echo $i | awk -F '.' '{print $2}')
		table_name=$(echo $i | awk -F '.' '{print $3}')
		start_log
		sql_outfile=$(mktemp)
		sql_errfile=$(mktemp)
		psql_rc=0
		if [ "$EXPLAIN_ANALYZE" == "false" ]; then
			echo "psql -d $DBNAME -c \"$PSQL_SESSION_SETS\" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE=\"\" -f $i | wc -l"
			set +e
			psql -d $DBNAME -c "$PSQL_SESSION_SETS" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE="" -f $i >"$sql_outfile" 2>"$sql_errfile"
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
			psql -d $DBNAME -c "$PSQL_SESSION_SETS" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE="EXPLAIN ANALYZE" -f $i >"$mylogfile" 2>"$sql_errfile"
			psql_rc=$?
			set -e
			if [ -s "$sql_errfile" ]; then
				cat "$sql_errfile" >&2
			fi
			tuples=$(tuples_from_explain_log "$mylogfile")
		fi
		QUERY_STATUS=$(sql_query_status "$sql_errfile" "$psql_rc")
		log $tuples
		unset QUERY_STATUS
		rm -f "$sql_outfile" "$sql_errfile"
	done
done

end_step $step
