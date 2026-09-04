#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
source $PWD/../../parse_step_args.sh
source $PWD/../../mode.sh
init_tpc_mode

echo "HEAP_ONLY: $HEAP_ONLY"
echo "REFERENCE_TABLE_TYPE: $REFERENCE_TABLE_TYPE"
echo "USE_EXTERNAL_FORMAT: $USE_EXTERNAL_FORMAT"
echo "EXTERNAL_HIVE_PARTITIONING: $EXTERNAL_HIVE_PARTITIONING"


#multiplying qiantity of partitions with EVERY=1 parameter in DDL
#EVERY_WEB_RETURNS is used for web_returns, it is by default "180" in a classic TPC-DS RunningJon

EVERY_WEB_RETURNS=$((180/$PARTITION_EVERY_FACTOR))
if [[ "$EVERY_WEB_RETURNS" == 0 ]]; then ((EVERY_WEB_RETURNS = 1 )); fi
echo "EVERY_WEB_RETURNS: $EVERY_WEB_RETURNS"

EVERY_CATALOG_RETURNS=$((8/$PARTITION_EVERY_FACTOR))
if [[ "$EVERY_CATALOG_RETURNS" == 0 ]]; then ((EVERY_CATALOG_RETURNS = 1 )); fi
echo "EVERY_CATALOG_RETURNS: $EVERY_CATALOG_RETURNS"

EVERY_STORE_SALES=$((10/$PARTITION_EVERY_FACTOR))
if [[ "$EVERY_STORE_SALES" == 0 ]]; then ((EVERY_STORE_SALES = 1 )); fi
echo "EVERY_STORE_SALES: $EVERY_STORE_SALES"

EVERY_CATALOG_SALES=$((28/$PARTITION_EVERY_FACTOR))
if [[ "$EVERY_CATALOG_SALES" == 0 ]]; then ((EVERY_CATALOG_SALES = 1 )); fi
echo "EVERY_CATALOG_SALES: $EVERY_CATALOG_SALES"

EVERY_WEB_SALES=$((40/$PARTITION_EVERY_FACTOR))
if [[ "$EVERY_WEB_SALES" == 0 ]]; then ((EVERY_WEB_SALES = 1 )); fi
echo "EVERY_WEB_SALES: $EVERY_WEB_SALES"

EVERY_STORE_RETURNS=$((100/$PARTITION_EVERY_FACTOR))
if [[ "$EVERY_STORE_RETURNS" == 0 ]]; then ((EVERY_STORE_RETURNS = 1 )); fi
echo "EVERY_STORE_RETURNS: $EVERY_STORE_RETURNS"

EVERY_INVENTORY=$((100/$PARTITION_EVERY_FACTOR))
if [[ "$EVERY_INVENTORY" == 0 ]]; then ((EVERY_INVENTORY = 1 )); fi
echo "EVERY_INVENTORY: $EVERY_INVENTORY"


if [[ "$GEN_DATA_SCALE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "You must provide the scale as a parameter in terms of Gigabytes, true/false to use random distrbution, multi-user count, and the number of sql iterations."
	echo "Example: ./rollout.sh 100 false false 5 1"
	exit 1
fi

step=ddl
init_log $step
get_version
source $PWD/../../external_format.sh

if [[ "$VERSION" == *"gpdb"* ]]; then
	filter="gpdb"
elif [ "$VERSION" == "postgresql" ]; then
	filter="postgresql"
else
	echo "ERROR: Unsupported VERSION $VERSION!"
	exit 1
fi

if { [ "$USE_EXTERNAL_FORMAT" = "parquet" ] || [ "$USE_EXTERNAL_FORMAT" = "csv" ] || [ "$USE_EXTERNAL_FORMAT" = "json" ]; } && [ "$filter" != "postgresql" ]; then
	echo "ERROR: USE_EXTERNAL_FORMAT=${USE_EXTERNAL_FORMAT} is only supported for PostgreSQL/pg_duckdb"
	exit 1
fi

get_psql_count()
{
        psql_count=$(ps -ef | grep psql | grep 03_ddl | grep -v grep | wc -l)
}

DDL_EVERY_ARGS=(
	-v EVERY_WEB_RETURNS="$EVERY_WEB_RETURNS"
	-v EVERY_CATALOG_RETURNS="$EVERY_CATALOG_RETURNS"
	-v EVERY_STORE_SALES="$EVERY_STORE_SALES"
	-v EVERY_CATALOG_SALES="$EVERY_CATALOG_SALES"
	-v EVERY_WEB_SALES="$EVERY_WEB_SALES"
	-v EVERY_STORE_RETURNS="$EVERY_STORE_RETURNS"
	-v EVERY_INVENTORY="$EVERY_INVENTORY"
)

if [ "$USE_EXTERNAL_FORMAT" = "parquet" ] || [ "$USE_EXTERNAL_FORMAT" = "csv" ] || [ "$USE_EXTERNAL_FORMAT" = "json" ]; then
	echo "Creating ${USE_EXTERNAL_FORMAT} views for schema ${TPC_SCHEMA} (no heap tables)"
	create_external_views
else
	echo "Creating DDL for schema ${TPC_SCHEMA}"
	create_tables_for_schema "$TPC_SCHEMA" "$filter" "${DDL_EVERY_ARGS[@]}"
	create_empty_catalog_schemas "$filter" "${DDL_EVERY_ARGS[@]}"
fi

#external tables are the same for all gpdb
if [ "$filter" == "gpdb" ] && [ "$USE_EXTERNAL_FORMAT" = "false" ]; then

	get_gpfdist_port

	for i in $(ls $PWD/*.ext_tpcds.*.sql); do
		start_log

		id=$(echo $i | awk -F '.' '{print $1}')
		schema_name=$(echo $i | awk -F '.' '{print $2}')
		table_name=$(echo $i | awk -F '.' '{print $3}')

		counter=0

		if [[ "$VERSION" == "gpdb_6" || "$VERSION" == "gpdb_7" ]]; then
			for x in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "select rank() over(partition by g.hostname order by g.datadir), g.hostname from gp_segment_configuration g where g.content >= 0 and g.role = 'p' order by g.hostname"); do
				CHILD=$(echo $x | awk -F '|' '{print $1}')
				EXT_HOST=$(echo $x | awk -F '|' '{print $2}')
				PORT=$(($GPFDIST_PORT + $CHILD))

				if [ "$counter" -eq "0" ]; then
					LOCATION="'"
				else
					LOCATION+="', '"
				fi
				LOCATION+="gpfdist://$EXT_HOST:$PORT/"$table_name"_[0-9]*_[0-9]*.dat"

				counter=$(($counter + 1))
			done
		else
			for x in $(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "select rank() over (partition by g.hostname order by p.fselocation), g.hostname from gp_segment_configuration g join pg_filespace_entry p on g.dbid = p.fsedbid join pg_tablespace t on t.spcfsoid = p.fsefsoid where g.content >= 0 and g.role = 'p' and t.spcname = 'pg_default' order by g.hostname"); do
				CHILD=$(echo $x | awk -F '|' '{print $1}')
				EXT_HOST=$(echo $x | awk -F '|' '{print $2}')
				PORT=$(($GPFDIST_PORT + $CHILD))

				if [ "$counter" -eq "0" ]; then
					LOCATION="'"
				else
					LOCATION+="', '"
				fi
				LOCATION+="gpfdist://$EXT_HOST:$PORT/"$table_name"_[0-9]*_[0-9]*.dat"

				counter=$(($counter + 1))
			done
		fi
		LOCATION+="'"

		#echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -a -P pager=off -f $i -v LOCATION=\"$LOCATION\""
		PGOPTIONS='--client-min-messages=warning' psql -d $DBNAME -v ON_ERROR_STOP=1 -q -P pager=off -f $i -v LOCATION="$LOCATION" 

		log
	done
fi

end_step $step
