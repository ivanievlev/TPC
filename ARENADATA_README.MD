# Arenadata version of TPC-DS
## Changes:

- Added support for Greenplum 7.x 
- Changed compression options from quicklz to zstd
- Added new parameters
- Added `REPO_BRANCH` parameter to select the git branch used by `tpcds.sh` (default: `master`)
- Added PostgreSQL/pg_duckdb local external formats: `USE_EXTERNAL_FORMAT` (`parquet`/`csv`/`json`), `EXTERNAL_HIVE_PARTITIONING`, `EXTERNAL_FILE_SIZE_BYTES`, `EXTERNAL_COMPRESSION`, `RUN_SQL_WITH_DUCKDB`, `PURGE_OLD_EXTERNAL_DATA`

## Installation

```
sudo su
mkdir /arenadata; cd /arenadata
git clone https://github.com/ivanievlev/TPC-DS.git
cd TPC-DS/
chmod 777 $(find /arenadata -type d)

<preliminary run to get paramater file>
nohup ./tpcds.sh > tpcds.log 2>&1 < tpcds.log &

<editing parameters>
nano tpcds_variables.sh

<main run>
nohup ./tpcds.sh > tpcds.log 2>&1 < tpcds.log &

<watching the log>
tail -f tpcds.log 

```

## Basic parameters

- REPO="TPC-DS"
- REPO_URL="https://github.com/ivanievlev/TPC-DS"
- REPO_BRANCH="master"
- ADMIN_USER="gpadmin"
- INSTALL_DIR="/arenadata"
- EXPLAIN_ANALYZE="false"
- RANDOM_DISTRIBUTION="false"
- MULTI_USER_COUNT="10"
- GEN_DATA_SCALE="3000"
- SINGLE_USER_ITERATIONS="1"
- RUN_COMPILE_TPCDS="true"
- RUN_GEN_DATA="false"
- RUN_INIT="false"
- RUN_DDL="false"
- RUN_LOAD="false"
- RUN_SQL="true"
- RUN_SINGLE_USER_REPORT="true"
- RUN_MULTI_USER="true"
- RUN_MULTI_USER_REPORT="true"
- RUN_SCORE="true"

	``Each RUN_*=false skips that step entirely in rollout.sh (the step script is not called).
	RUN_*=true removes the step's end_*.log and runs it. RUN_MULTI_USER and RUN_MULTI_USER_REPORT
	are independent: with MULTI_USER=false and MULTI_USER_REPORT=true the report still runs on
	whatever is already in log/rollout_testing_*.log.``

## New Arenadata parameters

- PARTITION_EVERY_FACTOR="1"
    
	``It is used in DDL step for tables with PARTITION BY <...> EVERY <...> to specify how much partitions will be used. 
	Specify default value = 1 for optimal number of partitions (693 in total in pg_partitions for db gpadmin), >= 180 to define maximum number of partitions (15337 in total in pg_partitions for db gpadmin) or value in between as you wish.``  
	
- EXCLUDE_HEAVY_QUERIES="true"

	``It is used to run only 51 simplified out of 99 queries to make test shorter. Specify true to exclude heavy queries.``

- EXTRA_TPCDS_SCHEMAS="0"

	``It is used to create similar schemas with *blank* objects to test great data catalog. Specify number of such extra schemas.`` 
	
- TRUNCATE_BEFORE_LOAD="true"

	``It is used to make purge faster with TRUNCATE commands instead of DELETE FROM.``
	
- SQL_ON_ERROR_STOP="true"

	``It is used to stop in case of every error. Essentially, errors shouldn't coour in stable environment. But for massive workload in unstable network you may specify "false" to skip trivial errors and make sure your test will complete.``

- STATEMENT_TIMEOUT="1h"

	``PostgreSQL statement_timeout for TPC-DS queries (single-user and multi-user). Examples: 1min, 30min, 1h. On timeout the query is cancelled; with SQL_ON_ERROR_STOP=true the SQL step stops.``

- DBNAME="gp_tpcds"

	``Default is gp_tpcds. Parameter was introduces to avoid conflicts of database "gpadmin" in case of concurrent TPC-H benchmark``

- RUN_SQL_FROM_ROLE="gpadmin"

	``We will run test from user that is set here. Default is gpadmin``

- REFERENCE_TABLE_TYPE="aoco"

	``Defines storage engine for tables with SMALL_STORAGE tag:
		aoco: "appendonly=true, orientation=column"
		aoro: "appendonly=true, orientation=row"
		heap: "appendonly=false"
	Default is "aoco", but in production system small reference tables are often updated/inserted and it make sense to set "heap" 
``

- HEAP_ONLY="false"

	``Default FALSE means that all tables (with tags SMALL_STORAGE, MEDIUM_STORAGE, LARGE_STORAGE) are Append-optimized as common in Greenplum. If TRUE it is used to make all these tables are heap ("appendonly=false").``

- SET_ORCA_OPTIMIZER="on"

	``Default ON uses Greenplum-native ORCA optimizer, while OFF - Postgres optimizer for all queries``

- MAKE_PREREQUISITES="false" and NETWORK_INTERFACE_JUMBOFRAME="eth0"

	``Default behaviour with MAKE_PREREQUISITES="false" does nothing. If MAKE_PREREQUISITES="true" then we will set mtu 9000 on all network interfaces with 		NETWORK_INTERFACE_JUMBOFRAME = "<name>" in all hosts (Jumbo Frame) and 	force start the cluster if it is not started``

- USE_EXTERNAL_FORMAT="false"

	``PostgreSQL/pg_duckdb only. Default "false" keeps the classic path: heap tables + COPY from .dat files.
	If "parquet", "csv" or "json", step 03 creates views over local files (no heap tables / PK / indexes), and step 04 converts .dat files into that format under
	/arenadata/tpcds_<GEN_DATA_SCALE>_<format>/<table>/ using pg_duckdb COPY ... WITH (FORMAT '<format>', ...).
	Views use read_parquet() / read_csv() / read_json() accordingly.
	No intermediate Postgres heap table is created for the load.``

- EXTERNAL_HIVE_PARTITIONING="false"

	``Used only when USE_EXTERNAL_FORMAT is parquet/csv/json. Default "false": flat dirs and hive_partitioning => false for read_parquet/read_csv.
	If set to "year, month", fact tables with a date_sk (inventory, store_sales/returns, catalog_sales/returns, web_sales/returns) are written with
	PARTITION_BY (year, month) hive directories (year/month taken from date_dim). Views for parquet/csv use hive_partitioning => true;
	read_json has no hive_partitioning argument, so json views use a recursive **/*.json glob.``

- EXTERNAL_FILE_SIZE_BYTES="-1"

	``Used only when USE_EXTERNAL_FORMAT is parquet/csv/json. Default "-1": do not pass FILE_SIZE_BYTES (no forced chunking; a single data.<ext> is written when hive is off).
	If set (e.g. "1GB"), FILE_SIZE_BYTES is added to the COPY options and files are split accordingly.``

- EXTERNAL_COMPRESSION="false"

	``Used only when USE_EXTERNAL_FORMAT is parquet/csv/json. Default "false": do not pass COMPRESSION.
	If set (e.g. "snappy", "zstd", "gzip"), COMPRESSION is added to the COPY options.
	For parquet the codec is stored inside the file and read_parquet needs no extra flag.
	For csv/json the whole file is compressed but still named *.csv/*.json, so views also pass
	compression => '<value>' to read_csv/read_json (otherwise DuckDB fails CSV sniffing).``

- PURGE_OLD_EXTERNAL_DATA="true"

	``On step 04_load, when "true" (default), delete previous external data directories matching
	/arenadata/tpcds_*_parquet, /arenadata/tpcds_*_csv and /arenadata/tpcds_*_json before loading.
	This frees space left by earlier scale/format runs (e.g. tpcds_3_parquet). When "false", those
	directories are left as-is (current tree may still be removed if TRUNCATE_BEFORE_LOAD=true and
	USE_EXTERNAL_FORMAT is parquet/csv/json).``

- RUN_SQL_WITH_DUCKDB="false"

	``PostgreSQL/pg_duckdb only. Default "false": steps 05 and 07 run as usual on Postgres.
	If "true", those steps set duckdb.force_execution TO true for each query session. With USE_EXTERNAL_FORMAT="false" DuckDB reads heap tables;
	with parquet/csv/json DuckDB reads the corresponding views.
	Validation: USE_EXTERNAL_FORMAT in {parquet,csv,json} requires RUN_SQL_WITH_DUCKDB="true", otherwise the run fails with:
	"<format> files can't be processed without DuckDB. Change format or activate DuckDB".
	At the start of the run, if RUN_SQL_WITH_DUCKDB="true", the script checks that extension pg_duckdb is present in
	pg_available_extensions and runs CREATE EXTENSION IF NOT EXISTS pg_duckdb; otherwise it exits with an error.``

## Parameters that are set during 02_init phase: Resource Groups limits (only for admin_group) and network sysctl parameters 

- net_core_rmem="26214400"
- net_core_wmem="26214400"
- rg6_memory_limit="80"
- rg6_memory_shared_quota="80"
- rg6_concurrency="100"
- rg6_cpu_rate_limit="70"
- rg7_cpu_hard_quota_limit="100"
