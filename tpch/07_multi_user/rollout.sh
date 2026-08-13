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

get_psql_count()
{
	psql_count=$(ps -ef | grep psql | grep multi_user | grep -v grep | wc -l)
}

get_file_count()
{
	file_count=$(ls $PWD/../../log/end_testing_log/end_testing*.log 2> /dev/null | wc -l)
}

get_file_count
if [ "$file_count" -ne "$MULTI_USER_COUNT" ]; then
	mkdir -p \
		$PWD/../../log/end_testing_log \
		$PWD/../../log/rollout_testing_log \
		$PWD/../../log/testing_session_log \
		$PWD/../../log/multi_explain_analyze_log
	rm -f $PWD/../../log/end_testing_log/end_testing_*.log
	rm -f $PWD/../../log/testing_session_log/testing_session_*.log
	rm -f $PWD/../../log/rollout_testing_log/rollout_testing_*.log
	rm -f $PWD/../../log/multi_explain_analyze_log/*multi.explain_analyze*.log

	#Create queries via qgen streams
	echo "cd $PWD/queries"
	cd $PWD/queries
	for i in $(seq 1 $MULTI_USER_COUNT); do
		sql_dir="$PWD"/tpch/"$i"
		echo "checking for directory $sql_dir"
		if [ ! -d "$sql_dir" ]; then
			echo "mkdir -p $sql_dir"
			mkdir -p $sql_dir
		fi
		echo "rm -f $sql_dir/*.sql"
		rm -f $sql_dir/*.sql
		echo "./qgen -p $i -c -v > $sql_dir/multi.sql"
		./qgen -p $i -c -v > $sql_dir/multi.sql
	done
	cd ..

	for x in $(seq 1 $MULTI_USER_COUNT); do
		session_log=$PWD/../../log/testing_session_log/testing_session_$x.log
		echo "$PWD/test.sh $GEN_DATA_SCALE $x $EXPLAIN_ANALYZE $EXCLUDE_HEAVY_QUERIES $SQL_ON_ERROR_STOP $DBNAME $STATEMENT_TIMEOUT $RUN_SQL_WITH_DUCKDB $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN \"$SKIP_QUERIES_LIST\""
		$PWD/test.sh $GEN_DATA_SCALE $x $EXPLAIN_ANALYZE $EXCLUDE_HEAVY_QUERIES $SQL_ON_ERROR_STOP $DBNAME $STATEMENT_TIMEOUT $RUN_SQL_WITH_DUCKDB $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN "$SKIP_QUERIES_LIST" |& tee $session_log &
	done

	sleep 60

	get_psql_count
	echo "Now executing queries. This make take a while."
	echo -ne "Executing queries."
	while [ "$psql_count" -gt "0" ]; do
		echo -ne "."
		sleep 60
		get_psql_count
	done
	echo "queries complete"
	echo ""

	get_file_count

	if [ "$file_count" -ne "$MULTI_USER_COUNT" ]; then
		echo "The number of successfully completed sessions is less than expected!"
		echo "Please review the log files to determine which queries failed."
		exit 1
	fi
fi
