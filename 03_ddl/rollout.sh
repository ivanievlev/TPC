#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../functions.sh
source_bashrc

GEN_DATA_SCALE=$1
EXPLAIN_ANALYZE=$2
RANDOM_DISTRIBUTION=$3
MULTI_USER_COUNT=$4
SINGLE_USER_ITERATIONS=$5
PARTITION_EVERY_FACTOR=$6
EXTRA_TPCDS_QUERIES=$8
HEAP_ONLY=${21}
REFERENCE_TABLE_TYPE=${26}
DBNAME=${27}
USE_EXTERNAL_FORMAT=${29}
EXTERNAL_HIVE_PARTITIONING=${30}
EXTERNAL_FILE_SIZE_BYTES=${31}
EXTERNAL_COMPRESSION=${32}
RUN_SQL_WITH_DUCKDB=${33}

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


if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "You must provide the scale as a parameter in terms of Gigabytes, true/false to run queries with EXPLAIN ANALYZE option, true/false to use random distrbution, multi-user count, and the number of sql iterations."
	echo "Example: ./rollout.sh 100 false false 5 1"
	exit 1
fi

step=ddl
init_log $step
get_version
source $PWD/../external_format.sh

if [[ "$VERSION" == *"gpdb"* ]]; then
	filter="gpdb"
elif [ "$VERSION" == "postgresql" ]; then
	filter="postgresql"
else
	echo "ERROR: Unsupported VERSION $VERSION!"
	exit 1
fi

if [ "$USE_EXTERNAL_FORMAT" = "parquet" ] && [ "$filter" != "postgresql" ]; then
	echo "ERROR: USE_EXTERNAL_FORMAT=parquet is only supported for PostgreSQL/pg_duckdb"
	exit 1
fi

get_psql_count()
{
        psql_count=$(ps -ef | grep psql | grep 03_ddl | grep -v grep | wc -l)
}


create_tables()
{
for i in $(ls $PWD/*.$filter.*.sql); do
	id=$(echo $i | awk -F '.' '{print $1}')
	schema_name=$(echo $i | awk -F '.' '{print $2}')
	table_name=$(echo $i | awk -F '.' '{print $3}')
	start_log

	if [ "$filter" == "gpdb" ]; then
		if [ "$RANDOM_DISTRIBUTION" == "true" ]; then
			DISTRIBUTED_BY="DISTRIBUTED RANDOMLY"
		else
			for z in $(cat $PWD/distribution.txt); do
				table_name2=$(echo $z | awk -F '|' '{print $2}')
				if [ "$table_name2" == "$table_name" ]; then
					distribution=$(echo $z | awk -F '|' '{print $3}')
				fi
			done
			DISTRIBUTED_BY="DISTRIBUTED BY (""$distribution"")"
		fi
	else
		DISTRIBUTED_BY=""
	fi

	#echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -P pager=off -f $i -v SMALL_STORAGE=\"$SMALL_STORAGE\" -v MEDIUM_STORAGE=\"$MEDIUM_STORAGE\" -v LARGE_STORAGE=\"$LARGE_STORAGE\" -v DISTRIBUTED_BY=\"$DISTRIBUTED_BY\""
	PGOPTIONS='--client-min-messages=warning' psql -d $DBNAME -v ON_ERROR_STOP=1 -q -P pager=off -f $i -v SMALL_STORAGE="$SMALL_STORAGE" -v MEDIUM_STORAGE="$MEDIUM_STORAGE" -v LARGE_STORAGE="$LARGE_STORAGE" -v DISTRIBUTED_BY="$DISTRIBUTED_BY" -v EVERY_WEB_RETURNS="$EVERY_WEB_RETURNS" -v EVERY_CATALOG_RETURNS="$EVERY_CATALOG_RETURNS" -v EVERY_STORE_SALES="$EVERY_STORE_SALES" -v EVERY_CATALOG_SALES="$EVERY_CATALOG_SALES" -v EVERY_WEB_SALES="$EVERY_WEB_SALES" -v EVERY_STORE_RETURNS="$EVERY_STORE_RETURNS" -v EVERY_INVENTORY="$EVERY_INVENTORY" -v SCHEMA=$1
	log
done
}

if [ "$USE_EXTERNAL_FORMAT" = "parquet" ]; then
	echo "Creating parquet views for schema TPCDS (no heap tables)"
	create_parquet_views
else
	echo "Creating DDL for schema TPCDS"
	create_tables "tpcds"

	echo "Creating DDL for extra schemas TPCDSx"
	for i in $(seq 1 $EXTRA_TPCDS_QUERIES); do
	        schema="tpcds$i"
		echo "Running stream$i for Creating DDL for schema $schema"
		echo "Now executing DDLs. This make take a while..."
	        create_tables "$schema" &
	done

	sleep 10

	get_psql_count
	while [ "$psql_count" -gt "0" ]; do
		echo -ne "."
	        sleep 10
	        get_psql_count
	done
	echo "done."
	echo ""
fi

#external tables are the same for all gpdb
if [ "$filter" == "gpdb" ] && [ "$USE_EXTERNAL_FORMAT" != "parquet" ]; then

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
