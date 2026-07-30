# Arenadata version of TPC-DS
## Changes:

- Added support for Greenplum 7.x 
- Changed compression options from quicklz to zstd
- Added new parameters
- Added `REPO_BRANCH` parameter to select the git branch used by `tpcds.sh` (default: `master`)

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

## Parameters that are set during 02_init phase: Resource Groups limits (only for admin_group) and network sysctl parameters 

- net_core_rmem="26214400"
- net_core_wmem="26214400"
- rg6_memory_limit="80"
- rg6_memory_shared_quota="80"
- rg6_concurrency="100"
- rg6_cpu_rate_limit="70"
- rg7_cpu_hard_quota_limit="100"
