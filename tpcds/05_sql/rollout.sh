#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc

GEN_DATA_SCALE=$1
EXPLAIN_ANALYZE=$2
RANDOM_DISTRIBUTION=$3
MULTI_USER_COUNT=$4
SINGLE_USER_ITERATIONS=$5
EXCLUDE_HEAVY_QUERIES=$7
SQL_ON_ERROR_STOP=${10}
DELETE_DAT_FILES_BEFORE_SQL="${18}"
RUN_SQL_FROM_ROLE="${19}"
DROP_CACHE_BEFORE_SQL="${20}"
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

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "You must provide the scale as a parameter in terms of Gigabytes, true/false to run queries with EXPLAIN ANALYZE option, true/false to use random distrbution, multi-user count, and the number of sql iterations."
	echo "Example: ./rollout.sh 100 false false 5 1"
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
validate_skip_queries_list "$SKIP_QUERIES_LIST"

step=sql
init_log $step

echo "SQL_ON_ERROR_STOP = $SQL_ON_ERROR_STOP"
echo "STATEMENT_TIMEOUT = $STATEMENT_TIMEOUT"
echo "RUN_SQL_WITH_DUCKDB = $RUN_SQL_WITH_DUCKDB"
echo "DUCKDB_MEMORY_LIMIT = $DUCKDB_MEMORY_LIMIT"
echo "DUCKDB_THREADS = $DUCKDB_THREADS"
echo "DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN = $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN"
echo "DUCKDB_THREADS_FOR_POSTGRES_SCAN = $DUCKDB_THREADS_FOR_POSTGRES_SCAN"
echo "SKIP_QUERIES_LIST = $SKIP_QUERIES_LIST"
echo "USE_EXTERNAL_FORMAT = $USE_EXTERNAL_FORMAT"
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

get_version
if [[ "$VERSION" == *"gpdb"* ]]; then
  echo "DELETE_DAT_FILES_BEFORE_SQL: $DELETE_DAT_FILES_BEFORE_SQL"
  if [ "$DELETE_DAT_FILES_BEFORE_SQL" == "true" ]; then
    gpssh -f /home/gpadmin/arenadata_configs/arenadata_segment_hosts.hosts -e 'rm -Rf /data1/primary/gpseg*/arenadata/*.dat'
  fi

  echo "Checking optimizer settings"
  gpconfig -s optimizer
fi

mkdir -p $PWD/../../log/single_explain_analyze_log
rm -f $PWD/../../log/single_explain_analyze_log/*single.explain_analyze*.log
for i in $(ls $PWD/*.tpcds.*.sql); do
	qnum=`echo $i | awk -F '.' '{print $3}'`
	if should_skip_tpcds_query "$qnum"; then
		echo "Skipping $qnum due to SKIP_QUERIES_LIST=${SKIP_QUERIES_LIST}."
		continue
	fi
	if [ "$EXCLUDE_HEAVY_QUERIES" == "true" ]; then

		if [[ 
		"$qnum" == "02" ||
		"$qnum" == "04" ||
		"$qnum" == "05" ||
		"$qnum" == "09" ||
		"$qnum" == "10" ||
		"$qnum" == "11" ||
		"$qnum" == "14" ||
		"$qnum" == "16" ||
		"$qnum" == "17" ||
		"$qnum" == "18" ||
		"$qnum" == "22" ||
		"$qnum" == "23" ||
		"$qnum" == "24" ||
		"$qnum" == "25" ||
		"$qnum" == "28" ||
		"$qnum" == "29" ||
		"$qnum" == "31" ||
		"$qnum" == "35" ||
		"$qnum" == "36" ||
		"$qnum" == "38" ||
		"$qnum" == "39" ||
		"$qnum" == "44" ||
		"$qnum" == "46" ||
		"$qnum" == "47" ||
		"$qnum" == "50" ||
		"$qnum" == "51" ||
		"$qnum" == "57" ||
		"$qnum" == "59" ||
		"$qnum" == "64" ||
		"$qnum" == "65" ||
		"$qnum" == "67" ||
		"$qnum" == "70" ||
		"$qnum" == "72" ||
		"$qnum" == "74" ||
		"$qnum" == "75" ||
		"$qnum" == "76" ||
		"$qnum" == "78" ||
		"$qnum" == "79" ||
		"$qnum" == "80" ||
		"$qnum" == "82" ||
		"$qnum" == "87" ||
		"$qnum" == "88" ||
		"$qnum" == "93" ||
		"$qnum" == "94" ||
		"$qnum" == "95" ||
		"$qnum" == "96" ||
		"$qnum" == "97" ||
		"$qnum" == "99" ]]; then

			echo "Skipping $qnum due to EXCLUDE_HEAVY_QUERIES=true."
		continue
		fi
	fi
	for x in $(seq 1 $SINGLE_USER_ITERATIONS); do
		id=`echo $i | awk -F '.' '{print $1}'`
		schema_name=`echo $i | awk -F '.' '{print $2}'`
		table_name=`echo $i | awk -F '.' '{print $3}'`
		start_log
		sql_outfile=$(mktemp)
		sql_errfile=$(mktemp)
		psql_rc=0
		if [ "$EXPLAIN_ANALYZE" == "false" ]; then
			echo "psql -d $DBNAME -U $RUN_SQL_FROM_ROLE -c \"$PSQL_SESSION_SETS\" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE=\"\" -f $i | wc -l"
			set +e
			psql -d $DBNAME -U $RUN_SQL_FROM_ROLE -c "$PSQL_SESSION_SETS" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE="" -f $i >"$sql_outfile" 2>"$sql_errfile"
			psql_rc=$?
			set -e
			# Keep stderr visible in the step log (same as before when psql wrote to the terminal).
			if [ -s "$sql_errfile" ]; then
				cat "$sql_errfile" >&2
			fi
			tuples=$(wc -l < "$sql_outfile" | tr -d ' ')
		else
			myfilename=$(basename $i)
			mylogfile=$PWD/../../log/single_explain_analyze_log/$myfilename.single.explain_analyze.log
			echo "psql -d $DBNAME -U $RUN_SQL_FROM_ROLE -c \"$PSQL_SESSION_SETS\" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE=\"EXPLAIN ANALYZE\" -f $i > $mylogfile"
			set +e
			psql -d $DBNAME -U $RUN_SQL_FROM_ROLE -c "$PSQL_SESSION_SETS" -v ON_ERROR_STOP=$ON_ERROR_STOP -A -q -t -P pager=off -v EXPLAIN_ANALYZE="EXPLAIN ANALYZE" -f $i >"$mylogfile" 2>"$sql_errfile"
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
