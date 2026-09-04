#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
source $PWD/../../parse_step_args.sh
source $PWD/../../mode.sh
init_tpc_mode

if [[ "$GEN_DATA_SCALE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" ]]; then
	echo "Missing required parameters from tpc_variables.sh (scale, random, multi-user count)."
	exit 1
fi
validate_skip_queries_list "$SKIP_QUERIES_LIST"

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

	rm -f $PWD/query_*.sql

	#create each session's directory
	sql_dir=$PWD/$session_id
	echo "sql_dir: $sql_dir"
	for i in $(seq 1 $MULTI_USER_COUNT); do
		sql_dir="$PWD"/"$session_id""$i"
		echo "checking for directory $sql_dir"
		if [ ! -d "$sql_dir" ]; then
			echo "mkdir $sql_dir"
			mkdir $sql_dir
		fi
		echo "rm -f $sql_dir/*.sql"
		rm -f $sql_dir/*.sql
	done

	#Create queries
	echo "cd $PWD"
	cd $PWD
	dsqgen_lst=$(mktemp)
	dsqgen_input_from_templates_lst "$PWD/query_templates/templates.lst" "$dsqgen_lst"
	echo "$PWD/dsqgen -streams $MULTI_USER_COUNT -input $dsqgen_lst -directory $PWD/query_templates -dialect pivotal -scale $GEN_DATA_SCALE -verbose y -output $PWD"
	$PWD/dsqgen -streams $MULTI_USER_COUNT -input "$dsqgen_lst" -directory $PWD/query_templates -dialect pivotal -scale $GEN_DATA_SCALE -verbose y -output $PWD
	rm -f "$dsqgen_lst"

	#move the query_x.sql file to the correct session directory
	for i in $(ls $PWD/query_*.sql); do
		stream_number=$(basename $i | awk -F '.' '{print $1}' | awk -F '_' '{print $2}')
		#going from base 0 to base 1
		stream_number=$((stream_number+1))
		echo "stream_number: $stream_number"
		sql_dir=$PWD/$stream_number
		echo "mv $i $sql_dir/"
		mv $i $sql_dir/
		# we substitute multi_user query with Jx_* prefix to tell them from single_user runs
		sed -i "s/tpcdsquery/mtpcdsquery_s${stream_number}of${MULTI_USER_COUNT}_/g"  $sql_dir/*.sql
		#sed -i "s/tpcdsquery/${MULTI_USER_COUNT}_/g"  $sql_dir/*.sql
	done

	session_pids=()
	for x in $(seq 1 $MULTI_USER_COUNT); do
		session_log=$PWD/../../log/testing_session_log/testing_session_$x.log
		echo "$PWD/test.sh $GEN_DATA_SCALE $x unused $EXCLUDE_HEAVY_QUERIES $SQL_ON_ERROR_STOP $DBNAME $STATEMENT_TIMEOUT $RUN_SQL_WITH_DUCKDB $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN \"$SKIP_QUERIES_LIST\""
		$PWD/test.sh $GEN_DATA_SCALE $x unused $EXCLUDE_HEAVY_QUERIES $SQL_ON_ERROR_STOP $DBNAME $STATEMENT_TIMEOUT $RUN_SQL_WITH_DUCKDB $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN "$SKIP_QUERIES_LIST" > >(tee "$session_log") 2>&1 &
		session_pids+=($!)
	done

	echo "Now executing queries. This may take a while."
	echo "Waiting for ${#session_pids[@]} multi-user session(s)."
	if ! wait_multi_user_sessions "${session_pids[@]}"; then
		echo "SQL_ON_ERROR_STOP=true: a multi-user session hit a query error. Stopping."
		exit 1
	fi
	echo "done."
	echo ""

	get_file_count

	if [ "$file_count" -ne "$MULTI_USER_COUNT" ]; then
		echo "WARNING: completed multi-user sessions=$file_count expected=$MULTI_USER_COUNT."
		echo "Continuing to reports/score with partial multi-user results. Review testing_session_*.log."
	fi
fi
