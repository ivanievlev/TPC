#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
source $PWD/../../parse_step_args.sh
source $PWD/../../mode.sh
init_tpc_mode

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "Missing required parameters from unified rollout (scale, explain, random, multi-user, iterations)."
	exit 1
fi

if [ "$MULTI_USER_COUNT" -eq "0" ]; then
	echo "MULTI_USER_COUNT set at 0 so exiting..."
	exit 0
fi

get_file_count()
{
	file_count=$(ls $PWD/../../log/end_testing_log/end_testing*.log 2> /dev/null | wc -l)
}

get_file_count
if [ "$file_count" -ne "$MULTI_USER_COUNT" ]; then
	mkdir -p \
		$PWD/../../log/end_testing_log \
		$PWD/../../log/rollout_testing_log \
		$PWD/../../log/testing_session_log
	rm -f $PWD/../../log/end_testing_log/end_testing_*.log
	rm -f $PWD/../../log/testing_session_log/testing_session_*.log
	rm -f $PWD/../../log/rollout_testing_log/rollout_testing_*.log

	#Create queries via qgen streams (do not rely on $PWD after cd — bash rewrites it)
	local_dir="$PWD"
	queries_dir="$local_dir/queries"
	echo "cd $queries_dir"
	cd "$queries_dir"
	for i in $(seq 1 $MULTI_USER_COUNT); do
		sql_dir="$local_dir/tpch/$i"
		echo "checking for directory $sql_dir"
		if [ ! -d "$sql_dir" ]; then
			echo "mkdir -p $sql_dir"
			mkdir -p "$sql_dir"
		fi
		echo "rm -f $sql_dir/*.sql"
		rm -f "$sql_dir"/*.sql
		echo "./qgen -p $i -c -v > $sql_dir/multi.sql"
		./qgen -p $i -c -v > "$sql_dir/multi.sql"
	done
	cd "$local_dir"

	session_pids=()
	for x in $(seq 1 $MULTI_USER_COUNT); do
		session_log=$local_dir/../../log/testing_session_log/testing_session_$x.log
		echo "$local_dir/test.sh $GEN_DATA_SCALE $x $EXPLAIN_ANALYZE $EXCLUDE_HEAVY_QUERIES $SQL_ON_ERROR_STOP $DBNAME $STATEMENT_TIMEOUT $RUN_SQL_WITH_DUCKDB $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN \"$SKIP_QUERIES_LIST\""
		$local_dir/test.sh $GEN_DATA_SCALE $x $EXPLAIN_ANALYZE $EXCLUDE_HEAVY_QUERIES $SQL_ON_ERROR_STOP $DBNAME $STATEMENT_TIMEOUT $RUN_SQL_WITH_DUCKDB $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN "$SKIP_QUERIES_LIST" > >(tee "$session_log") 2>&1 &
		session_pids+=($!)
	done

	echo "Now executing queries. This may take a while."
	echo "Waiting for ${#session_pids[@]} multi-user session(s)."
	if ! wait_multi_user_sessions "${session_pids[@]}"; then
		echo "SQL_ON_ERROR_STOP=true: a multi-user session hit a query error. Stopping."
		exit 1
	fi
	echo "queries complete"
	echo ""

	get_file_count

	if [ "$file_count" -ne "$MULTI_USER_COUNT" ]; then
		echo "WARNING: completed multi-user sessions=$file_count expected=$MULTI_USER_COUNT."
		echo "Continuing to reports/score with partial multi-user results. Review testing_session_*.log."
	fi
fi
