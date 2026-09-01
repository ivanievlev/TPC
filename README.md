# Unified TPC harness (TPC-DS + TPC-H)

The clone directory name is always `TPC`. `tpc.sh` reads `REPO_URL` from `git remote get-url origin` (not from `tpc_variables.sh`).

Select the benchmark with:

```bash
TPC_MODE="TPC-DS"   # default — tpcds/00_compile_tpcds … tpcds/09_score
TPC_MODE="TPC-H"    # tpch/00_compile_tpch … tpch/09_score
```

Knobs live in `tpc_variables.sh`, grouped as Generic, Steps, Postgres-specific, Greenplum-specific, TPCDS-specific, and TPCH-specific. Each variable has a one-sentence comment. Copy `tpc_variables.sh.example` for a starting template. Entry point: `./tpc.sh`.

TPC-H assets live under `tpch/`. Score (`09_score`) and `USE_EXTERNAL_FORMAT` (parquet/csv/json) are available for both TPC-DS and TPC-H. Score reports 05_sql (`1 User Queries`, TPT, Score, success %) **per `SINGLE_USER_ITERATIONS` pass**, plus DAT/TBL size, DB or external storage size, 07 success rate, and (when `COLLECT_OS_DATA=true`) OS CPU/RAM/network/disk averages per host for those steps (every Patroni member when the cluster is present).

---

# Arenadata version of TPC-DS
## Changes:

- Added support for Greenplum 7.x 
- Changed compression options from quicklz to zstd
- Added new parameters
- Added `REPO_BRANCH` parameter to select the git branch used by `tpc.sh` (default: `main`)
- Added PostgreSQL/pg_duckdb local external formats: `USE_EXTERNAL_FORMAT` (`parquet`/`csv`/`json`), `EXTERNAL_HIVE_PARTITIONING`, `EXTERNAL_FILE_SIZE_BYTES`, `EXTERNAL_COMPRESSION`, `RUN_SQL_WITH_DUCKDB`, `DUCKDB_MEMORY_LIMIT`, `DUCKDB_THREADS`, `DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN`, `DUCKDB_THREADS_FOR_POSTGRES_SCAN`, `PURGE_OLD_EXTERNAL_DATA`, `KILL_PREVIOUS_PROCESSES`, `SKIP_TPCDS_QUERIES_LIST`, `SKIP_TPCH_QUERIES_LIST`

## Installation

```
git clone https://github.com/ivanievlev/TPC.git
cd TPC/

# Run as a normal user with passwordless sudo (sudo -n true). Do not run as root /
# via sudo ./tpc.sh — the script refuses root and uses sudo only for privileged steps.
# All logs, segment_hosts.txt and step artifacts stay in this clone.
# ADMIN_USER (gpadmin/postgres) must be able to cd/read/write this directory
# (compile, load, ssh); 02_init fails if that is not true.

<preliminary run to get paramater file>
nohup ./tpc.sh > tpc.log 2>&1 < tpc.log &

<editing parameters>
nano tpc_variables.sh

<main run>
nohup ./tpc.sh > tpc.log 2>&1 < tpc.log &

<watching the log>
tail -f tpc.log 

When the run finishes successfully, the last line is:
The end. All TPC-DS steps completed
(or All TPC-H steps completed, depending on TPC_MODE)

A timestamped copy of `tpc.log` is also saved under `log/archived_results/`:
`<YYYYMMDD_HHMMSS>_tpcds_SF<scale>_<format>[_with-duckdb].log` (or `tpch_…`)
(`format` is `heap`, or `parquet`/`csv`/`json`; `_with-duckdb` only when `RUN_SQL_WITH_DUCKDB=true`).
Timestamp-first naming sorts chronologically for later analysis.

Step logs go into subdirectories of `log/`:
- `log/end_testing_log/end_testing_*.log`
- `log/rollout_testing_log/rollout_testing_*.log`
- `log/testing_session_log/testing_session_*.log`
- `log/single_explain_analyze_log/*sql.single.explain_analyze*.log`
- `log/multi_explain_analyze_log/*sql.multi.explain_analyze*.log`

```

## Basic parameters

See `tpc_variables.sh` for the full list (section order: Generic, Steps, Postgres-specific, Greenplum-specific, TPCDS-specific, TPCH-specific).

- REPO_BRANCH="main"
- TPC_MODE="TPC-DS"
- ADMIN_USER="postgres"
- DAT_FILE_DIRECTORY_PATH="/tmp"
- EXTERNAL_FILE_DIRECTORY_PATH="/tmp"
- EXPLAIN_ANALYZE="false"
- RANDOM_DISTRIBUTION="false"
- MULTI_USER_COUNT="10"
- GEN_DATA_SCALE="3000"
- SINGLE_USER_ITERATIONS="1"
- RUN_GEN_DATA="false"
- RUN_INIT="false"
- RUN_DDL="false"
- RUN_LOAD="false"
- RUN_SINGLE_USER="true"
- RUN_MULTI_USER="true"

	``Each RUN_*=false skips that step entirely in rollout.sh (the step script is not called).
	RUN_*=true removes the step's end_*.log and runs it.
	Compile (00_compile_tpcds / 00_compile_tpch) and score (09_score) always run; there are no RUN_COMPILE_TPC or RUN_SCORE flags.
	RUN_SINGLE_USER=true always runs 05_sql and then 06_single_user_reports.
	RUN_MULTI_USER=true always runs 07_multi_user and then 08_multi_user_reports.
	There are no separate report flags.``

## New Arenadata parameters

- DAT_FILE_DIRECTORY_PATH="/tmp"

	``Absolute root for generated .dat / .tbl files (default "/tmp"). The relative path under that root is hardcoded as ../datfiles (not a user knob).
	Greenplum / gpfdist: /tmp/primary/gpseg0/../datfiles (i.e. /tmp/primary/datfiles), and the same on other primaries;
	PostgreSQL: /tmp/datfiles_1, /tmp/datfiles_2, …
	Independent of EXTERNAL_FILE_DIRECTORY_PATH so flat files and parquet/csv/json can sit on different disks.
	Must be an absolute path without '..'.``

- EXTERNAL_FILE_DIRECTORY_PATH="/tmp"

	``Absolute root for parquet/csv/json trees (default "/tmp"), not for .dat files.
	parquet/csv/json: /tmp/tpcds_<scale>_<format>/ (or tpch_…).
	Must be an absolute path without '..'.``

- PARTITION_EVERY_FACTOR="1"
    
	``It is used in DDL step for tables with PARTITION BY <...> EVERY <...> to specify how much partitions will be used. 
	Specify default value = 1 for optimal number of partitions (693 in total in pg_partitions for db gpadmin), >= 180 to define maximum number of partitions (15337 in total in pg_partitions for db gpadmin) or value in between as you wish.``  
	
- EXCLUDE_HEAVY_QUERIES="true"

	``It is used to run only 51 simplified out of 99 queries to make test shorter. Specify true to exclude heavy queries.``

- SKIP_TPCDS_QUERIES_LIST=""

	``Comma-separated TPC-DS query numbers (1..99) to skip in steps 05 (single-user) and 07 (multi-user) when TPC_MODE=TPC-DS.
	Default empty: run all queries (subject to EXCLUDE_HEAVY_QUERIES).
	Examples: SKIP_TPCDS_QUERIES_LIST="85" or SKIP_TPCDS_QUERIES_LIST="1,64,85".
	Invalid values fail at startup: out-of-range (e.g. 164) or non-integer (e.g. n4).``

- SKIP_TPCH_QUERIES_LIST=""

	``Comma-separated TPC-H query numbers (1..22) to skip in steps 05 and 07 when TPC_MODE=TPC-H.
	Default empty: run all 22 queries. Examples: SKIP_TPCH_QUERIES_LIST="1" or SKIP_TPCH_QUERIES_LIST="1,7,22".
	Invalid values fail at startup.``

- EMPTY_SCHEMAS_CNT="0"

	``Number of extra schemas with the same *blank* (empty) objects as the main schema, for catalog stress tests.
	Works for both TPC-DS and TPC-H: creates tpcds1..N or tpch1..N. Former name: EXTRA_TPCDS_SCHEMAS.``

- TRUNCATE_BEFORE_LOAD="true"

	``It is used to make purge faster with TRUNCATE commands instead of DELETE FROM.``
	
- SQL_ON_ERROR_STOP="true"

	``Stop 05_sql and 07_multi_user when a query is classified as ERROR (any concurrent session). statement_timeout is not an error: the query is marked cancelled due to timeout and the run continues. Set false to keep going after query errors (unstable network / expected failures).``

- STATEMENT_TIMEOUT="1h"

	``PostgreSQL statement_timeout for 05_sql and 07_multi_user. Examples: 1min, 30min, 1h. On timeout the query is cancelled and recorded; SQL_ON_ERROR_STOP does not treat timeout as an error.``

- DBNAME="pg_tpc"

	``Default is pg_tpc. Parameter was introduces to avoid conflicts of database "gpadmin" in case of concurrent TPC-H benchmark``

- PGPORT_WRITE="5432"

	``TCP port for write/admin steps: 01_gen_data, 02_init, 03_ddl, 04_load, 06_single_user_reports, 08_multi_user_reports, 09_score (and compile/setup). Default 5432.``

- PGPORT_SELECT="5432"

	``TCP port for query workload: 05_sql and 07_multi_user. Default 5432.
	Example: PGPORT_WRITE="5432" PGPORT_SELECT="6433" to run queries via HAProxy replicas while DDL/load stay on the primary.``

- PGHOST=""

	``Empty (default): libpq uses a Unix socket /tmp/.s.PGSQL.<PGPORT> — this is Postgres or PgBouncer, not HAProxy.
	HAProxy listens on TCP only. To send load through HAProxy set PGHOST="127.0.0.1" and the matching PGPORT_WRITE / PGPORT_SELECT.
	Use 127.0.0.1 (not localhost) so the client does not fall back to a Unix socket.``

- RUN_SQL_FROM_ROLE="postgres"

	``We will run test from user that is set here. Default is postgres``

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
	<EXTERNAL_FILE_DIRECTORY_PATH>/tpcds_<GEN_DATA_SCALE>_<format>/<table>/ using pg_duckdb COPY ... WITH (FORMAT '<format>', ...).
	Views use read_parquet() / read_csv() / read_json() accordingly.
	No intermediate Postgres heap table is created for the load.``

- EXTERNAL_HIVE_PARTITIONING="false"

	``Used only when USE_EXTERNAL_FORMAT is parquet/csv/json. Allowed values: "true" or "false" (default "false").
	If "false": flat dirs and hive_partitioning => false for read_parquet/read_csv.
	If "true": fact tables with a date_sk (inventory, store_sales/returns, catalog_sales/returns, web_sales/returns) are written with
	PARTITION_BY (year, month) hive directories (year/month taken from date_dim). Views for parquet/csv use hive_partitioning => true;
	read_json has no hive_partitioning argument, so json views use a recursive **/*.json glob.
	Incompatible with EXTERNAL_FILE_SIZE_BYTES other than "-1" (startup error).``

- EXTERNAL_FILE_SIZE_BYTES="-1"

	``Used only when USE_EXTERNAL_FORMAT is parquet/csv/json. Default "-1": do not pass FILE_SIZE_BYTES (no forced chunking; a single data.<ext> is written when hive is off).
	If set (e.g. "1GB"), FILE_SIZE_BYTES is added to the COPY options and files are split accordingly.
	Incompatible with EXTERNAL_HIVE_PARTITIONING enabled: DuckDB cannot combine FILE_SIZE_BYTES and PARTITION_BY;
	the run fails at startup asking to keep only one of the two.``

- EXTERNAL_COMPRESSION="false"

	``Used only when USE_EXTERNAL_FORMAT is parquet/csv/json. Default "false": do not pass COMPRESSION.
	If set (e.g. "snappy", "zstd", "gzip"), COMPRESSION is added to the COPY options.
	For parquet the codec is stored inside the file and read_parquet needs no extra flag.
	For csv/json the whole file is compressed but still named *.csv/*.json, so views also pass
	compression => '<value>' to read_csv/read_json (otherwise DuckDB fails CSV sniffing).``

- PURGE_OLD_EXTERNAL_DATA="true"

	``On step 04_load, when "true" (default), delete previous external data directories matching
	<EXTERNAL_FILE_DIRECTORY_PATH>/tpcds_*_parquet, …_*_csv and …_*_json before loading.
	This frees space left by earlier scale/format runs (e.g. tpcds_3_parquet). When "false", those
	directories are left as-is (current tree may still be removed if TRUNCATE_BEFORE_LOAD=true and
	USE_EXTERNAL_FORMAT is parquet/csv/json).``

- KILL_PREVIOUS_PROCESSES="true"

	``At the start of tpc.sh (after variables are printed), when "true" (default), find leftover
	TPC Linux processes from a previous unfinished run (tpc.sh, rollout.sh, multi-user test.sh,
	dsqgen/dbgen/qgen, psql -f .../TPC/...) and terminate them (TERM, then KILL). Also runs pg_terminate_backend
	on leftover client sessions in DBNAME so orphan queries cannot block DROP SCHEMA/DDL. The current
	tpc.sh and its ancestors are never killed. When "false", no process cleanup is done.``

- DROP_CACHE_BEFORE_SQL="false"

	``Default "false". When "true", immediately before the first 05_sql iteration:
	`sync && echo 3 > /proc/sys/vm/drop_caches` (via passwordless sudo) to drop the OS page cache.
	If SINGLE_USER_ITERATIONS>1, later iterations do not drop the cache (they reuse OS page cache
	from the first pass). Score prints 1 User Queries / TPT / Score / 05_sql success % per iteration.
	Applies to both TPC-DS and TPC-H. Does not drop cache before each individual query or before multi-user.``

- RUN_SQL_WITH_DUCKDB="false"

	``PostgreSQL/pg_duckdb only. Default "false": steps 05 and 07 run as usual on Postgres.
	If "true", those steps set duckdb.force_execution TO true for each query session.
	duckdb.memory_limit / duckdb.threads / duckdb.max_workers_per_postgres_scan / duckdb.threads_for_postgres_scan
	are applied once in 02_init (ALTER DATABASE DBNAME SET …) together with pgconfig, not per query.
	With USE_EXTERNAL_FORMAT="false" DuckDB reads heap tables;
	with parquet/csv/json DuckDB reads the corresponding views.
	Validation: USE_EXTERNAL_FORMAT in {parquet,csv,json} requires RUN_SQL_WITH_DUCKDB="true", otherwise the run fails with:
	"<format> files can't be processed without DuckDB. Change format or activate DuckDB".
	At the start of the run, if RUN_SQL_WITH_DUCKDB="true", the script ensures database DBNAME exists,
	checks pg_extension, and runs CREATE EXTENSION IF NOT EXISTS pg_duckdb when missing.
	Fails only if CREATE EXTENSION itself fails (package/shared library not installed on the server).``

- COLLECT_OS_DATA="true"

	``Default "true": starts an OS metrics collector for the duration of the run (no Prometheus / exporters required).
	Samples CPU, RAM, network, and disk into log/os_metrics/<host>.csv. On a Patroni cluster every member is sampled
	(SSH as the tpc.sh invoker); otherwise only the local host. Step 09_score prints per-host averages over the
	05_sql and 07_multi_user time windows. Set to "false" to skip collection and omit OS metric rows from the score.``

- COLLECT_DATA_PERIOD="5s"

	``Sampling interval for the OS metrics collector when COLLECT_OS_DATA=true. Same duration syntax as STATEMENT_TIMEOUT
	(e.g. "1s", "5s", "1min", "1m", "2h"). Values below 1 second are rounded up to 1s. Default "5s".``

- DUCKDB_MEMORY_LIMIT="4GB"

	``Used when RUN_SQL_WITH_DUCKDB="true". Applied once in 02_init via ALTER DATABASE SET duckdb.memory_limit
	(replicates to standbys). Default "4GB". Raise this (e.g. "16GB") if queries hit DuckDB Out of Memory errors.``

- DUCKDB_THREADS="-1"

	``Used when RUN_SQL_WITH_DUCKDB="true". Applied once in 02_init via ALTER DATABASE SET duckdb.threads.
	Default "-1" (DuckDB chooses).``

- DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN="2"

	``Used when RUN_SQL_WITH_DUCKDB="true". Applied once in 02_init via ALTER DATABASE SET duckdb.max_workers_per_postgres_scan.
	Default "2" (pg_duckdb boot default).``

- DUCKDB_THREADS_FOR_POSTGRES_SCAN="2"

	``Used when RUN_SQL_WITH_DUCKDB="true". Applied once in 02_init via ALTER DATABASE SET duckdb.threads_for_postgres_scan.
	Default "2" (pg_duckdb boot default).``

## Parameters that are set during 02_init phase: Resource Groups limits (only for admin_group) and network sysctl parameters 

- net_core_rmem="26214400"
- net_core_wmem="26214400"
- rg6_memory_limit="80"
- rg6_memory_shared_quota="80"
- rg6_concurrency="100"
- rg6_cpu_rate_limit="70"
- rg7_cpu_hard_quota_limit="100"
