#!/bin/bash

set -e

GEN_DATA_SCALE=$1
EXPLAIN_ANALYZE=$2
RANDOM_DISTRIBUTION=$3
MULTI_USER_COUNT=$4
EXCLUDE_HEAVY_QUERIES=$7
SQL_ON_ERROR_STOP=${10}
DBNAME=${27}
STATEMENT_TIMEOUT=${28}
USE_EXTERNAL_FORMAT=${29}
EXTERNAL_HIVE_PARTITIONING=${30}
EXTERNAL_FILE_SIZE_BYTES=${31}
EXTERNAL_COMPRESSION=${32}
RUN_SQL_WITH_DUCKDB=${33}
DUCKDB_MEMORY_LIMIT=${35}
DUCKDB_THREADS=${36}
DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN=${37}
DUCKDB_THREADS_FOR_POSTGRES_SCAN=${38}
SKIP_QUERIES_LIST=${41}


if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" ]]; then
        echo "You must provide the scale as a parameter in terms of Gigabytes, true/false to run queries with EXPLAIN ANALYZE option, true/false to use random distrbution, and the number of concurrent users to run."
        echo "Example: ./rollout.sh 100 false false 5"
        echo "This will create 100 GB of data for this test, not run EXPLAIN ANALYZE, not use random distribution and use 5 sessions for the multi-user test."
        exit 1
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
if [ -z "${SKIP_QUERIES_LIST+x}" ]; then
	SKIP_QUERIES_LIST=""
fi
# functions.sh is sourced below after PWD is set for multi-user; validate after that.

if [ "$MULTI_USER_COUNT" -eq "0" ]; then
	echo "MULTI_USER_COUNT set at 0 so exiting..."
	exit 0
fi

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
set_tpc_pgport_for_step "$PWD"
apply_tpc_pgport
validate_skip_queries_list "$SKIP_QUERIES_LIST"

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
	echo "$PWD/dsqgen -streams $MULTI_USER_COUNT -input $PWD/query_templates/templates.lst -directory $PWD/query_templates -dialect pivotal -scale $GEN_DATA_SCALE -verbose y -output $PWD"
	$PWD/dsqgen -streams $MULTI_USER_COUNT -input $PWD/query_templates/templates.lst -directory $PWD/query_templates -dialect pivotal -scale $GEN_DATA_SCALE -verbose y -output $PWD

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
		echo "$PWD/test.sh $GEN_DATA_SCALE $x $EXPLAIN_ANALYZE $EXCLUDE_HEAVY_QUERIES $SQL_ON_ERROR_STOP $DBNAME $STATEMENT_TIMEOUT $RUN_SQL_WITH_DUCKDB $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN \"$SKIP_QUERIES_LIST\""
		$PWD/test.sh $GEN_DATA_SCALE $x $EXPLAIN_ANALYZE $EXCLUDE_HEAVY_QUERIES $SQL_ON_ERROR_STOP $DBNAME $STATEMENT_TIMEOUT $RUN_SQL_WITH_DUCKDB $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN "$SKIP_QUERIES_LIST" |& tee $session_log &
		session_pids+=($!)
	done

	echo "Now executing queries. This may take a while."
	echo "Waiting for ${#session_pids[@]} multi-user session(s)."
	# Wait on session pipelines (test.sh | tee). Do not grep psql argv for
	# "multi_user": psql -f is a /tmp wrapper (backend host probe).
	set +e
	for pid in "${session_pids[@]}"; do
		wait "$pid"
	done
	set -e
	echo "done."
	echo ""

	get_file_count

	if [ "$file_count" -ne "$MULTI_USER_COUNT" ]; then
		echo "WARNING: completed multi-user sessions=$file_count expected=$MULTI_USER_COUNT."
		echo "Continuing to reports/score with partial multi-user results. Review testing_session_*.log."
	fi
fi
