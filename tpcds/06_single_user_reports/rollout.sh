#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc

DBNAME=${27}


step=single_user_reports

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

for i in $(ls $PWD/*.copy.*.sql); do
	logstep=$(echo $i | awk -F 'copy.' '{print $2}' | awk -F '.' '{print $1}')
	logfile="$PWD/../../log/rollout_${logstep}.log"
	ensure_rollout_log_for_copy "$logfile"
	if [ "$logstep" = "sql" ]; then
		pad_sql_log_backend_host "$logfile"
	fi
	logfile="'""$logfile""'"
	echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -a -f $i -v LOGFILE=\"$logfile\""
	psql -d $DBNAME -v ON_ERROR_STOP=1 -a -f $i -v LOGFILE="$logfile"
	echo ""
done

psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "select 'analyze ' || n.nspname || '.' || c.relname || ';' from pg_class c join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'tpcds_reports'" | psql -d $DBNAME -v ON_ERROR_STOP=1 -t -A -e

# Aligned columns (not -A/-F tab): keeps table readable when name/value widths differ.
report_sql()
{
	psql -d "$DBNAME" -v ON_ERROR_STOP=1 -P pager=off -P format=aligned -P border=1 -f "$1"
}

echo "********************************************************************************"
echo "Generate Data"
echo "********************************************************************************"
report_sql "$PWD/gen_data_report.sql"
echo ""
echo "********************************************************************************"
echo "Data Loads"
echo "********************************************************************************"
report_sql "$PWD/loads_report.sql"
echo ""
echo "********************************************************************************"
echo "Constraints after load"
echo "********************************************************************************"
report_sql "$PWD/constraints_report.sql"
echo ""
echo "********************************************************************************"
echo "Analyze"
echo "********************************************************************************"
report_sql "$PWD/analyze_report.sql"
echo ""
echo ""
echo "********************************************************************************"
echo "Queries"
echo "********************************************************************************"
psql_report_with_query_labels "$PWD/../00_compile_tpcds/query_templates/templates.lst" "$PWD/queries_report.sql" -P pager=off -P format=aligned -P border=1
echo ""
end_step $step
