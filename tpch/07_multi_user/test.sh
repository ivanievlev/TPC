#!/bin/bash

set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source $PWD/../../mode.sh
init_tpc_mode

GEN_DATA_SCALE=$1
session_id=$2
# $3 is leftover EXPLAIN_ANALYZE from the unified arg list; 07 never uses it.
EXCLUDE_HEAVY_QUERIES=$4
SQL_ON_ERROR_STOP=$5
DBNAME=$6
STATEMENT_TIMEOUT=$7
RUN_SQL_WITH_DUCKDB=$8
DUCKDB_MEMORY_LIMIT=$9
DUCKDB_THREADS=${10}
DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN=${11}
DUCKDB_THREADS_FOR_POSTGRES_SCAN=${12}
SKIP_QUERIES_LIST=${13}

if [[ "$session_id" == "" ]]; then
	echo "Error: you must provide the session id as a parameter."
	exit 1
fi
if [ -z "$STATEMENT_TIMEOUT" ]; then
	STATEMENT_TIMEOUT="1h"
fi
if [ -z "$RUN_SQL_WITH_DUCKDB" ]; then
	RUN_SQL_WITH_DUCKDB="false"
fi
if [ -z "$SQL_ON_ERROR_STOP" ]; then
	SQL_ON_ERROR_STOP="true"
fi
if [ "$SQL_ON_ERROR_STOP" == "true" ]; then
	ON_ERROR_STOP=1
else
	ON_ERROR_STOP=0
fi

source_bashrc
set_tpc_pgport_for_step "$PWD"
apply_tpc_pgport

step=testing_$session_id
init_log $step

sql_dir=$PWD/tpch/$session_id
query_id=100

for order in $(seq 1 22); do
	query_id=$((query_id+1))
	query_number=$(grep begin $sql_dir/multi.sql | head -n"$order" | tail -n1 | awk -F ' ' '{print $2}' | awk -F 'q' '{print $2}')
	start_position=$(grep -n "begin q""$query_number" $sql_dir/multi.sql | awk -F ':' '{print $1}')
	end_position=$(grep -n "end q""$query_number" $sql_dir/multi.sql | awk -F ':' '{print $1}')
	target_filename="$query_id"".query.""$query_number"".sql"
	echo ":EXPLAIN_ANALYZE" > $sql_dir/$target_filename
	sed -n "$start_position","$end_position"p $sql_dir/multi.sql >> $sql_dir/$target_filename
done
rm -f $sql_dir/multi.sql

PSQL_SESSION_SETS="SET statement_timeout='$STATEMENT_TIMEOUT';"
if [ "$RUN_SQL_WITH_DUCKDB" == "true" ]; then
	PSQL_SESSION_SETS="$PSQL_SESSION_SETS SET duckdb.force_execution TO true;"
	PSQL_SESSION_SETS="$PSQL_SESSION_SETS SET duckdb.memory_limit TO '$DUCKDB_MEMORY_LIMIT';"
	PSQL_SESSION_SETS="$PSQL_SESSION_SETS SET duckdb.threads TO $DUCKDB_THREADS;"
	PSQL_SESSION_SETS="$PSQL_SESSION_SETS SET duckdb.max_workers_per_postgres_scan TO $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN;"
	PSQL_SESSION_SETS="$PSQL_SESSION_SETS SET duckdb.threads_for_postgres_scan TO $DUCKDB_THREADS_FOR_POSTGRES_SCAN;"
fi

for i in $(ls $sql_dir/*.sql); do
	qnum=$(basename $i | awk -F '.' '{print $3}')
	if should_skip_tpcds_query "$qnum"; then
		echo "Skipping $qnum due to SKIP_QUERIES_LIST=${SKIP_QUERIES_LIST}."
		continue
	fi

	start_log
	schema_name=$session_id
	table_name=$(basename $i | awk -F '.' '{print $3}')
	sql_outfile=$(mktemp)
	sql_errfile=$(mktemp)
	hostfile=$(mktemp)
	psql_rc=0

	echo "psql -d $DBNAME -c \"$PSQL_SESSION_SETS\" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE=\"\" -f $i | wc -l"
	set +e
	psql_run_sql_capturing_host "$i" "$sql_outfile" "$sql_errfile" "$hostfile" ""
	psql_rc=$?
	set -e
	if [ -s "$sql_errfile" ]; then
		cat "$sql_errfile" >&2
	fi
	tuples=$(wc -l < "$sql_outfile" | tr -d ' ')
	if [ "$tuples" -gt 0 ]; then
		tuples=$((tuples - 1))
	fi

	QUERY_STATUS=$(sql_query_status "$sql_errfile" "$psql_rc")
	log $tuples
	unset QUERY_STATUS QUERY_BACKEND_HOST
	rm -f "$sql_outfile" "$sql_errfile" "$hostfile"
done

end_step $step
