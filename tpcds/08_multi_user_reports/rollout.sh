#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
DBNAME=${27}


step="multi_user_reports"

init_log $step

get_version
if [[ "$VERSION" == *"gpdb"* ]]; then
	filter="gpdb"
elif [ "$VERSION" == "postgresql" ]; then
	filter="postgresql"
else
	echo "ERROR: Unsupported VERSION!"
	exit 1
fi

for i in $(ls $PWD/*.$filter.*.sql); do
	echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -a -f $i"
	psql -d $DBNAME -v ON_ERROR_STOP=1 -a -f $i
	echo ""
done

filename=$(ls $PWD/*.copy.*.sql)

for i in $(ls $PWD/../../log/rollout_testing_log/rollout_testing_*.log 2> /dev/null); do
	logfile="'""$i""'"
	
        echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -a -f $filename -v LOGFILE=\"$logfile\""
        psql -d $DBNAME -v ON_ERROR_STOP=1 -a -f $filename -v LOGFILE="$logfile"
done

psql -d $DBNAME -v ON_ERROR_STOP=1 -t -A -c "select 'analyze ' || n.nspname || '.' || c.relname || ';' from pg_class c join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'tpcds_testing'" | psql -d $DBNAME -v ON_ERROR_STOP=1 -t -A -e

psql -d $DBNAME -v ON_ERROR_STOP=1 -P pager=off -P format=aligned -P border=1 -f $PWD/detailed_report.sql
echo ""

end_step $step
