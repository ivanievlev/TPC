#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

MYCMD="tpc.sh"
MYVAR="tpc_variables.sh"
##################################################################################################################################################
# Functions
##################################################################################################################################################
# Privileged ops as root via passwordless sudo (script itself never runs as root).
run_priv()
{
	sudo -n -- "$@"
}

# Run a bash -lc command as ADMIN_USER (replaces su -l / su -c).
# Login shells source ~/.bashrc (which may set PGPORT/PGHOST); re-export harness values after that.
# Admin/setup psql uses PGPORT_WRITE.
as_admin()
{
	local cmd="$1"
	local port_write="${PGPORT_WRITE:-5432}"
	local port_select="${PGPORT_SELECT:-5432}"
	local port="${PGPORT:-$port_write}"
	local envcmd="export PGPORT_WRITE=\"${port_write}\" PGPORT_SELECT=\"${port_select}\" PGPORT=\"${port}\"; unset PGHOST;"
	if [ -n "${PGHOST:-}" ]; then
		envcmd="${envcmd} export PGHOST=\"${PGHOST}\";"
	fi
	cmd="${envcmd} ${cmd}"
	if [ "$(id -un)" = "$ADMIN_USER" ]; then
		bash -lc "$cmd"
	else
		sudo -n -u "$ADMIN_USER" -H bash -lc "$cmd"
	fi
}

check_variables()
{
	new_variable="0"

	### Migrate legacy filename if present
	if [ ! -f "$PWD/$MYVAR" ] && [ -f "$PWD/tpcds_variables.sh" ]; then
		echo "Renaming tpcds_variables.sh -> $MYVAR"
		mv "$PWD/tpcds_variables.sh" "$PWD/$MYVAR"
	fi

	### Make sure variables file is available
	if [ ! -f "$PWD/$MYVAR" ]; then
		touch $PWD/$MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "REPO=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "REPO=\"TPC\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "REPO_URL=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "REPO_URL=\"https://github.com/ivanievlev/TPC\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "REPO_BRANCH=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "REPO_BRANCH=\"main\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "TPC_MODE=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "TPC_MODE=\"TPC-DS\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "ADMIN_USER=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "ADMIN_USER=\"postgres\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
        local count=$(grep "DBNAME=" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "DBNAME=\"pg_tpc\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi
	# PORT / PGPORT → PGPORT_WRITE + PGPORT_SELECT
	_legacy_pgport=""
	if grep -q '^PORT=' "$MYVAR" 2>/dev/null; then
		_legacy_pgport=$(grep '^PORT=' "$MYVAR" | tail -1 | sed 's/^PORT=//; s/^"//; s/"$//; s/[[:space:]]*#.*//')
		sed -i '/^PORT=/d' "$MYVAR"
		new_variable=$(($new_variable + 1))
	fi
	if grep -q '^PGPORT=' "$MYVAR" 2>/dev/null; then
		_legacy_pgport=$(grep '^PGPORT=' "$MYVAR" | tail -1 | sed 's/^PGPORT=//; s/^"//; s/"$//; s/[[:space:]]*#.*//')
		echo "Renaming PGPORT -> PGPORT_WRITE and PGPORT_SELECT in $MYVAR"
		sed -i '/^PGPORT=/d' "$MYVAR"
		new_variable=$(($new_variable + 1))
	fi
	if ! grep -q '^PGPORT_WRITE=' "$MYVAR" 2>/dev/null; then
		echo "PGPORT_WRITE=\"${_legacy_pgport:-5432}\"  # steps 01-04, 06, 08-09 (init, DDL, load, reports, score)" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	if ! grep -q '^PGPORT_SELECT=' "$MYVAR" 2>/dev/null; then
		echo "PGPORT_SELECT=\"${_legacy_pgport:-5432}\"  # steps 05_sql and 07_multi_user (query workload)" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	unset _legacy_pgport
	local count=$(grep '^PGHOST=' $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo 'PGHOST="" # if empty then uses local connection via `unix_socket_directories`' >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	# INSTALL_DIR used to be the clone parent (/arenadata). Runtime is now
	# this checkout; the name lives on as the gpfdist .dat subdirectory.
	if grep -q '^INSTALL_DIR=' "$MYVAR" 2>/dev/null; then
		if ! grep -q '^DAT_FILE_SUBDIRECTORY_NAME=' "$MYVAR" 2>/dev/null; then
			_old_install_dir=$(grep '^INSTALL_DIR=' "$MYVAR" | tail -1 | sed 's/^INSTALL_DIR=//; s/^"//; s/"$//')
			_dat_name=$(basename -- "${_old_install_dir:-arenadata}")
			[ -z "$_dat_name" ] && _dat_name="arenadata"
			echo "Renaming INSTALL_DIR -> DAT_FILE_SUBDIRECTORY_NAME=\"$_dat_name\" in $MYVAR"
			echo "DAT_FILE_SUBDIRECTORY_NAME=\"$_dat_name\"" >> "$MYVAR"
			unset _old_install_dir _dat_name
		fi
		sed -i '/^INSTALL_DIR=/d' "$MYVAR"
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "DAT_FILE_SUBDIRECTORY_NAME=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "DAT_FILE_SUBDIRECTORY_NAME=\"datfiles\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "EXTERNAL_FILE_DIRECTORY_PATH=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "EXTERNAL_FILE_DIRECTORY_PATH=\"/tmp\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "EXPLAIN_ANALYZE=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "EXPLAIN_ANALYZE=\"false\"  # affects only 05_sql (single-user) and ignored by 07_multi_user" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "RANDOM_DISTRIBUTION=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RANDOM_DISTRIBUTION=\"false\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "MULTI_USER_COUNT" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "MULTI_USER_COUNT=\"5\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "GEN_DATA_SCALE" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "GEN_DATA_SCALE=\"3000\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "SINGLE_USER_ITERATIONS" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "SINGLE_USER_ITERATIONS=\"1\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
        local count=$(grep "PARTITION_EVERY_FACTOR" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "PARTITION_EVERY_FACTOR=\"1\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi
        local count=$(grep "EXCLUDE_HEAVY_QUERIES" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "EXCLUDE_HEAVY_QUERIES=\"false\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi
	local count=$(grep "SKIP_QUERIES_LIST" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "SKIP_QUERIES_LIST=\"\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	# Migrate legacy EXTRA_TPCDS_SCHEMAS → EMPTY_SCHEMAS_CNT
	if grep -q '^EXTRA_TPCDS_SCHEMAS=' "$MYVAR" 2>/dev/null; then
		if ! grep -q '^EMPTY_SCHEMAS_CNT=' "$MYVAR" 2>/dev/null; then
			echo "Renaming EXTRA_TPCDS_SCHEMAS -> EMPTY_SCHEMAS_CNT in $MYVAR"
			sed -i 's/^EXTRA_TPCDS_SCHEMAS=/EMPTY_SCHEMAS_CNT=/' "$MYVAR"
		else
			sed -i '/^EXTRA_TPCDS_SCHEMAS=/d' "$MYVAR"
		fi
	fi
	local count=$(grep "EMPTY_SCHEMAS_CNT" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "EMPTY_SCHEMAS_CNT=\"0\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
        local count=$(grep "TRUNCATE_BEFORE_LOAD" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "TRUNCATE_BEFORE_LOAD=\"true\"" >> $MYVAR
                new_variable=$(($new_variable + 1))

        fi
        local count=$(grep "SQL_ON_ERROR_STOP" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "SQL_ON_ERROR_STOP=\"true\"" >> $MYVAR
                new_variable=$(($new_variable + 1))

        fi
	local count=$(grep "STATEMENT_TIMEOUT" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "STATEMENT_TIMEOUT=\"1h\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi

	#00
	# Migrate legacy RUN_COMPILE_TPCDS → RUN_COMPILE_TPC
	if grep -q '^RUN_COMPILE_TPCDS=' "$MYVAR" 2>/dev/null; then
		if ! grep -q '^RUN_COMPILE_TPC=' "$MYVAR" 2>/dev/null; then
			echo "Renaming RUN_COMPILE_TPCDS -> RUN_COMPILE_TPC in $MYVAR"
			sed -i 's/^RUN_COMPILE_TPCDS=/RUN_COMPILE_TPC=/' "$MYVAR"
		else
			sed -i '/^RUN_COMPILE_TPCDS=/d' "$MYVAR"
		fi
	fi
	local count=$(grep "RUN_COMPILE_TPC" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_COMPILE_TPC=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	#01
	local count=$(grep "RUN_GEN_DATA" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_GEN_DATA=\"false\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	#02
	local count=$(grep "RUN_INIT" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_INIT=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	#03
	local count=$(grep "RUN_DDL" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_DDL=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	#04
	local count=$(grep "RUN_LOAD" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_LOAD=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	#05
	local count=$(grep "RUN_SQL" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_SQL=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	#06
	local count=$(grep "RUN_SINGLE_USER_REPORT" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_SINGLE_USER_REPORT=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	#07
	local count=$(grep "RUN_MULTI_USER" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_MULTI_USER=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	#08
	local count=$(grep "RUN_MULTI_USER_REPORT" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_MULTI_USER_REPORT=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	#09
	local count=$(grep "RUN_SCORE" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_SCORE=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi

	local count=$(grep "net_core_rmem" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "net_core_rmem=\"26214400\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

		local count=$(grep "net_core_wmem" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "net_core_wmem=\"26214400\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

		local count=$(grep "rg6_memory_limit" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "rg6_memory_limit=\"80\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

		local count=$(grep "rg6_memory_shared_quota" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "rg6_memory_shared_quota=\"80\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

		local count=$(grep "rg6_concurrency" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "rg6_concurrency=\"100\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi
		
		local count=$(grep "rg6_cpu_rate_limit" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "rg6_cpu_rate_limit=\"70\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi
		
		local count=$(grep "rg7_cpu_hard_quota_limit" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "rg7_cpu_hard_quota_limit=\"100\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

        local count=$(grep "DELETE_DAT_FILES_BEFORE_SQL" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "DELETE_DAT_FILES_BEFORE_SQL=\"false\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

        local count=$(grep "RUN_SQL_FROM_ROLE" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "RUN_SQL_FROM_ROLE=\"postgres\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

        local count=$(grep "REFERENCE_TABLE_TYPE" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "REFERENCE_TABLE_TYPE=\"aoco\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

	# Migrate DROP_CACHE_BEFORE_EACH_SINGLE_QUERY → DROP_CACHE_BEFORE_SQL
	if grep -q '^DROP_CACHE_BEFORE_EACH_SINGLE_QUERY=' "$MYVAR" 2>/dev/null; then
		sed -i 's/^DROP_CACHE_BEFORE_EACH_SINGLE_QUERY=/DROP_CACHE_BEFORE_SQL=/' "$MYVAR"
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "DROP_CACHE_BEFORE_SQL" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "DROP_CACHE_BEFORE_SQL=\"false\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi

        local count=$(grep "HEAP_ONLY" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "HEAP_ONLY=\"false\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

        local count=$(grep "MAKE_PREREQUISITES" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "MAKE_PREREQUISITES=\"false\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

        local count=$(grep "NETWORK_INTERFACE_JUMBOFRAME" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "NETWORK_INTERFACE_JUMBOFRAME=\"eth0\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

        local count=$(grep "SET_ORCA_OPTIMIZER" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "SET_ORCA_OPTIMIZER=\"on\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

	local count=$(grep "USE_EXTERNAL_FORMAT" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "USE_EXTERNAL_FORMAT=\"false\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "EXTERNAL_HIVE_PARTITIONING" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "EXTERNAL_HIVE_PARTITIONING=\"false\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "EXTERNAL_FILE_SIZE_BYTES" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "EXTERNAL_FILE_SIZE_BYTES=\"-1\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "EXTERNAL_COMPRESSION" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "EXTERNAL_COMPRESSION=\"false\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "RUN_SQL_WITH_DUCKDB" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_SQL_WITH_DUCKDB=\"false\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "PURGE_OLD_EXTERNAL_DATA" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "PURGE_OLD_EXTERNAL_DATA=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "KILL_PREVIOUS_PROCESSES" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "KILL_PREVIOUS_PROCESSES=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "DUCKDB_MEMORY_LIMIT" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "DUCKDB_MEMORY_LIMIT=\"4GB\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "DUCKDB_THREADS" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "DUCKDB_THREADS=\"-1\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN=\"2\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "DUCKDB_THREADS_FOR_POSTGRES_SCAN" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "DUCKDB_THREADS_FOR_POSTGRES_SCAN=\"2\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	# Migrate Prometheus knobs → local OS collector
	if grep -q '^COLLECT_PROMETHEUS_DATA=' "$MYVAR" 2>/dev/null && ! grep -q '^COLLECT_OS_DATA=' "$MYVAR" 2>/dev/null; then
		sed -i 's/^COLLECT_PROMETHEUS_DATA=/COLLECT_OS_DATA=/' "$MYVAR"
		new_variable=$(($new_variable + 1))
	fi
	if grep -q '^PROMETHEUS_URL=' "$MYVAR" 2>/dev/null; then
		sed -i '/^PROMETHEUS_URL=/d' "$MYVAR"
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "COLLECT_OS_DATA" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "COLLECT_OS_DATA=\"true\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "COLLECT_DATA_PERIOD" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "COLLECT_DATA_PERIOD=\"5s\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "APPLY_PGCONFIG_PARAMETERS" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "APPLY_PGCONFIG_PARAMETERS=\"false\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi

	if [ "$new_variable" -gt "0" ]; then
		echo "There are new variables in the tpc_variables.sh file.  Please review to ensure the values are correct and then re-run this script."
		exit 1
	fi
	echo "############################################################################"
	echo "Sourcing $MYVAR"
	echo "############################################################################"
	echo ""
	# Migrate legacy clone identity from the old TPC-DS repository name.
	if grep -q '^REPO="TPC-DS"' "$MYVAR" 2>/dev/null; then
		sed -i 's/^REPO="TPC-DS"/REPO="TPC"/' "$MYVAR"
	fi
	if grep -q '^REPO_URL="https://github.com/ivanievlev/TPC-DS"' "$MYVAR" 2>/dev/null; then
		sed -i 's|^REPO_URL="https://github.com/ivanievlev/TPC-DS"|REPO_URL="https://github.com/ivanievlev/TPC"|' "$MYVAR"
	fi
	source $MYVAR
	if [ -z "${SKIP_QUERIES_LIST+x}" ]; then
		SKIP_QUERIES_LIST=""
	fi
	_dat="$DAT_FILE_SUBDIRECTORY_NAME"
	_dat="${_dat%/}"
	if [[ "$_dat" == */* ]]; then
		if [[ "$_dat" =~ ^/[^/]+$ ]]; then
			_dat="${_dat#/}"
		else
			echo "ERROR: DAT_FILE_SUBDIRECTORY_NAME must be a single directory name (got: $DAT_FILE_SUBDIRECTORY_NAME)."
			echo "Example: DAT_FILE_SUBDIRECTORY_NAME=\"datfiles\" → /tmp/primary/gpseg0/datfiles"
			exit 1
		fi
	fi
	DAT_FILE_SUBDIRECTORY_NAME="$_dat"
	unset _dat
	if [ -z "$DAT_FILE_SUBDIRECTORY_NAME" ] || [ "$DAT_FILE_SUBDIRECTORY_NAME" = "." ] || [ "$DAT_FILE_SUBDIRECTORY_NAME" = ".." ]; then
		echo "ERROR: DAT_FILE_SUBDIRECTORY_NAME must be a single directory name (e.g. datfiles)."
		exit 1
	fi
	if [[ ! "$DAT_FILE_SUBDIRECTORY_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
		echo "ERROR: DAT_FILE_SUBDIRECTORY_NAME contains invalid characters: $DAT_FILE_SUBDIRECTORY_NAME"
		echo "Use a name like datfiles (no slashes or spaces)."
		exit 1
	fi
	_ext="$EXTERNAL_FILE_DIRECTORY_PATH"
	_ext="${_ext#"${_ext%%[![:space:]]*}"}"
	_ext="${_ext%"${_ext##*[![:space:]]}"}"
	_ext="${_ext%/}"
	if [[ "$_ext" != /* ]]; then
		echo "ERROR: EXTERNAL_FILE_DIRECTORY_PATH must be an absolute directory (got: $EXTERNAL_FILE_DIRECTORY_PATH)."
		echo "Use the root only (e.g. /tmp). .dat files are written under"
		echo "  \$EXTERNAL_FILE_DIRECTORY_PATH/primary/gpseg<N>/\$DAT_FILE_SUBDIRECTORY_NAME"
		exit 1
	fi
	if [[ "$_ext" == */../* || "$_ext" == */.. || "$_ext" == ../* || "$_ext" == .. ]]; then
		echo "ERROR: EXTERNAL_FILE_DIRECTORY_PATH must not contain '..' (got: $_ext)."
		exit 1
	fi
	EXTERNAL_FILE_DIRECTORY_PATH="$_ext"
	unset _ext
	if [ -z "${PGPORT_WRITE:-}" ] && [ -z "${PGPORT_SELECT:-}" ]; then
		if [ -n "${PGPORT:-}" ]; then
			PGPORT_WRITE="$PGPORT"
			PGPORT_SELECT="$PGPORT"
		elif [ -n "${PORT:-}" ]; then
			PGPORT_WRITE="$PORT"
			PGPORT_SELECT="$PORT"
		fi
	fi
	if [ -z "${PGPORT_WRITE:-}" ]; then
		PGPORT_WRITE="5432"
	fi
	if [ -z "${PGPORT_SELECT:-}" ]; then
		PGPORT_SELECT="5432"
	fi
	for _pname in PGPORT_WRITE PGPORT_SELECT; do
		eval "_pval=\$$_pname"
		_pval="${_pval#"${_pval%%[![:space:]]*}"}"
		_pval="${_pval%"${_pval##*[![:space:]]}"}"
		if ! [[ "$_pval" =~ ^[0-9]+$ ]]; then
			echo "ERROR: $_pname must be an integer 1..65535 (got: $_pval)."
			exit 1
		fi
		_port=$((10#$_pval))
		if [ "$_port" -lt 1 ] || [ "$_port" -gt 65535 ]; then
			echo "ERROR: $_pname must be an integer 1..65535 (got: $_pval)."
			exit 1
		fi
		eval "$_pname=$_port"
	done
	unset _pname _pval _port
	PGPORT="${PGPORT_WRITE}"
	export PGPORT_WRITE PGPORT_SELECT PGPORT
	PGHOST="${PGHOST#"${PGHOST%%[![:space:]]*}"}"
	PGHOST="${PGHOST%"${PGHOST##*[![:space:]]}"}"
	if [ -z "$PGHOST" ]; then
		unset PGHOST
	else
		export PGHOST
	fi
	# Inline validation (tpc.sh does not source functions.sh — avoid clobbering ADMIN_USER).
	_skip_list=$(echo "${SKIP_QUERIES_LIST}" | tr -d '[:space:]')
	if [ -n "$_skip_list" ]; then
		IFS=',' read -ra _skip_items <<< "$_skip_list"
		for _item in "${_skip_items[@]}"; do
			if [ -z "$_item" ]; then
				echo "ERROR: SKIP_QUERIES_LIST has an empty entry (got: ${SKIP_QUERIES_LIST})"
				echo "Expected comma-separated query numbers in 1..99, e.g. \"85\" or \"1,64,85\"."
				exit 1
			fi
			if ! [[ "$_item" =~ ^[0-9]+$ ]]; then
				echo "ERROR: SKIP_QUERIES_LIST invalid entry \"$_item\" (must be an integer 1..99)."
				echo "Example: SKIP_QUERIES_LIST=\"85\" or SKIP_QUERIES_LIST=\"1,64,85\"."
				exit 1
			fi
			_n=$((10#$_item))
			if [ "$_n" -lt 1 ] || [ "$_n" -gt 99 ]; then
				echo "ERROR: SKIP_QUERIES_LIST query $_n is out of range (must be 1..99)."
				echo "Example: SKIP_QUERIES_LIST=\"85\" or SKIP_QUERIES_LIST=\"1,64,85\"."
				exit 1
			fi
		done
	fi
	unset _skip_list _skip_items _item _n
}

check_user()
{
	### Never run as root: require a normal user with passwordless sudo. ###
	echo "############################################################################"
	echo "Make sure the caller is a non-root user with passwordless sudo."
	echo "############################################################################"
	echo ""
	if [ "$(id -u)" -eq 0 ]; then
		echo "ERROR: do not run $MYCMD as root."
		echo "Run it as a normal user (e.g. luka). Privileged steps use sudo."
		exit 1
	fi
	if ! command -v sudo >/dev/null 2>&1; then
		echo "ERROR: sudo is required."
		exit 1
	fi
	# nohup/redirected stdin cannot prompt for a password — require NOPASSWD.
	if ! sudo -n true 2>/dev/null; then
		echo "ERROR: passwordless sudo failed for $(whoami) (sudo -n)."
		echo "Configure NOPASSWD in sudoers for this user."
		exit 1
	fi
	# Repair config left root-owned by older runs.
	if [ -f "$PWD/$MYVAR" ] && [ ! -w "$PWD/$MYVAR" ]; then
		run_priv chown "$(whoami):" "$PWD/$MYVAR" 2>/dev/null || true
	fi
	echo "Running as $(whoami); privileged ops via sudo."
}

yum_installs()
{
	### Install and Update Demos ###
	echo "############################################################################"
	echo "Install git, gcc, and bc with yum."
	echo "############################################################################"
	echo ""
	# Install git and gcc if not found
	local YUM_INSTALLED=$(yum --help 2> /dev/null | wc -l)
	local CURL_INSTALLED=$(gcc --help 2> /dev/null | wc -l)
	local GIT_INSTALLED=$(git --help 2> /dev/null | wc -l)
	local BC_INSTALLED=$(bc --help 2> /dev/null | wc -l)

	if [ "$YUM_INSTALLED" -gt "0" ]; then
		if [ "$CURL_INSTALLED" -eq "0" ]; then
			run_priv yum -y install gcc
		fi
		if [ "$GIT_INSTALLED" -eq "0" ]; then
			run_priv yum -y install git
		fi
		if [ "$BC_INSTALLED" -eq "0" ]; then
			run_priv yum -y install bc
		fi
	else
		if [ "$CURL_INSTALLED" -eq "0" ]; then
			echo "gcc not installed and yum not found to install it."
			echo "Please install gcc and try again."
			exit 1
		fi
		if [ "$GIT_INSTALLED" -eq "0" ]; then
			echo "git not installed and yum not found to install it."
			echo "Please install git and try again."
			exit 1
		fi
		if [ "$BC_INSTALLED" -eq "0" ]; then
			echo "bc not installed and yum not found to install it."
			echo "Please install bc and try again."
			exit 1
		fi
	fi
	echo ""
}

# Uncommitted-change check against the clone where ./tpc.sh was started.
require_launch_tree_clean()
{
	local launch dirty
	launch=$(readlink -f "$PWD")
	if [ ! -d "$launch/.git" ]; then
		echo "ERROR: $launch is not a git repository."
		echo "tpc.sh must be started from a git checkout so uncommitted changes can be detected."
		exit 1
	fi
	dirty=$(cd "$launch" && git status --porcelain 2>/dev/null | wc -l)
	if [ "$dirty" -gt "0" ]; then
		echo "ERROR: repository $launch has uncommitted changes."
		echo "Please commit (or stash) them before running tpc.sh, then re-run."
		echo ""
		(cd "$launch" && git status --short) || true
		exit 1
	fi
}

# Fetch/checkout REPO_BRANCH in this clone. No second tree, no overlay.
repo_init()
{
	local tpc_hash_before tpc_hash_after internet_down

	echo "############################################################################"
	echo "Using git clone at $PWD"
	echo "############################################################################"
	echo ""

	require_launch_tree_clean

	if [ -z "$REPO_BRANCH" ]; then
		REPO_BRANCH="main"
	fi

	tpc_hash_before=$(cksum "$PWD/$MYCMD" | awk '{print $1" "$2}')

	internet_down="0"
	for j in $(curl google.com 2>&1 | grep "Couldn't resolve host"); do
		internet_down="1"
	done

	if [ "$internet_down" -eq "0" ]; then
		(cd "$PWD" && GIT_SSL_NO_VERIFY=true git fetch origin "$REPO_BRANCH" || true) || true
	fi

	(
		cd "$PWD"
		if git rev-parse --verify "$REPO_BRANCH" >/dev/null 2>&1; then
			echo "Checking out local branch $REPO_BRANCH (keeping local commits)"
			git checkout "$REPO_BRANCH"
		elif git rev-parse --verify "origin/$REPO_BRANCH" >/dev/null 2>&1; then
			echo "Local branch $REPO_BRANCH missing; creating from origin/$REPO_BRANCH"
			git checkout -b "$REPO_BRANCH" "origin/$REPO_BRANCH"
		else
			echo "ERROR: branch $REPO_BRANCH not found locally or on origin"
			exit 1
		fi
		echo "Now on branch: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
	)

	tpc_hash_after=$(cksum "$PWD/$MYCMD" | awk '{print $1" "$2}')
	if [ "$tpc_hash_before" != "$tpc_hash_after" ]; then
		echo "$MYCMD changed after checking out $REPO_BRANCH."
		echo "Re-run: ./$MYCMD"
		exit 1
	fi
}

# ADMIN_USER must be able to cd/read/write this clone (compile, log/, load scripts).
# Full compile/load/ssh check runs in 02_init; this is the gate so as_admin can start.
require_admin_can_enter_clone()
{
	local repo="$PWD"
	local err
	local probe="log/.admin_write_probe_$$"

	echo "############################################################################"
	echo "Checking ADMIN_USER=$ADMIN_USER can use clone $repo"
	echo "############################################################################"

	if ! err=$(as_admin "cd \"$repo\" && test -r tpc.sh && test -x rollout.sh && test -r functions.sh && mkdir -p log && touch $probe && rm -f $probe" 2>&1); then
		echo "ERROR: ADMIN_USER=$ADMIN_USER cannot run compile/load/ssh from clone $repo"
		echo "$err"
		echo "Grant $ADMIN_USER traverse+read+write on $repo (compile dirs, log/, scripts)."
		echo "02_init will also refuse to continue until this is fixed."
		exit 1
	fi
	echo "ADMIN_USER=$ADMIN_USER can enter $repo"
	echo ""
}

echo_variables()
{
	echo "############################################################################"
	echo "REPO: $REPO"
	echo "REPO_URL: $REPO_URL"
	echo "REPO_BRANCH: $REPO_BRANCH"
	echo "ADMIN_USER: $ADMIN_USER"
	echo "DBNAME: $DBNAME"
	echo "PGPORT_WRITE: $PGPORT_WRITE"
	echo "PGPORT_SELECT: $PGPORT_SELECT"
	echo "PGHOST: ${PGHOST:-}"
	echo "DAT_FILE_SUBDIRECTORY_NAME: $DAT_FILE_SUBDIRECTORY_NAME"
	echo "EXTERNAL_FILE_DIRECTORY_PATH: $EXTERNAL_FILE_DIRECTORY_PATH"
	echo "MULTI_USER_COUNT: $MULTI_USER_COUNT"
	echo "PARTITION_EVERY_FACTOR: $PARTITION_EVERY_FACTOR"
	echo "EXCLUDE_HEAVY_QUERIES: $EXCLUDE_HEAVY_QUERIES"
	echo "SKIP_QUERIES_LIST: $SKIP_QUERIES_LIST"
        echo "EMPTY_SCHEMAS_CNT: $EMPTY_SCHEMAS_CNT"
	echo "TRUNCATE_BEFORE_LOAD: $TRUNCATE_BEFORE_LOAD"
	echo "SQL_ON_ERROR_STOP: $SQL_ON_ERROR_STOP"
	echo "STATEMENT_TIMEOUT: $STATEMENT_TIMEOUT"
	echo "net_core_rmem: $net_core_rmem"
	echo "net_core_wmem: $net_core_wmem"
	echo "rg6_memory_limit: $rg6_memory_limit"
	echo "rg6_memory_shared_quota: $rg6_memory_shared_quota"
	echo "rg6_concurrency: $rg6_concurrency"
	echo "rg6_cpu_rate_limit: $rg6_cpu_rate_limit"
	echo "rg7_cpu_hard_quota_limit: $rg7_cpu_hard_quota_limit"
	echo "DELETE_DAT_FILES_BEFORE_SQL: $DELETE_DAT_FILES_BEFORE_SQL"
	echo "RUN_SQL_FROM_ROLE: $RUN_SQL_FROM_ROLE"
	echo "REFERENCE_TABLE_TYPE: $REFERENCE_TABLE_TYPE"
	echo "DROP_CACHE_BEFORE_SQL: $DROP_CACHE_BEFORE_SQL"
	echo "HEAP_ONLY: $HEAP_ONLY"
	echo "MAKE_PREREQUISITES: $MAKE_PREREQUISITES"
	echo "NETWORK_INTERFACE_JUMBOFRAME: $NETWORK_INTERFACE_JUMBOFRAME"
	echo "SET_ORCA_OPTIMIZER: $SET_ORCA_OPTIMIZER"
	echo "USE_EXTERNAL_FORMAT: $USE_EXTERNAL_FORMAT"
	echo "EXTERNAL_HIVE_PARTITIONING: $EXTERNAL_HIVE_PARTITIONING"
	echo "EXTERNAL_FILE_SIZE_BYTES: $EXTERNAL_FILE_SIZE_BYTES"
	echo "EXTERNAL_COMPRESSION: $EXTERNAL_COMPRESSION"
	echo "RUN_SQL_WITH_DUCKDB: $RUN_SQL_WITH_DUCKDB"
	echo "DUCKDB_MEMORY_LIMIT: $DUCKDB_MEMORY_LIMIT"
	echo "DUCKDB_THREADS: $DUCKDB_THREADS"
	echo "DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN: $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN"
	echo "DUCKDB_THREADS_FOR_POSTGRES_SCAN: $DUCKDB_THREADS_FOR_POSTGRES_SCAN"
	echo "COLLECT_OS_DATA: $COLLECT_OS_DATA"
	echo "COLLECT_DATA_PERIOD: $COLLECT_DATA_PERIOD"
	echo "APPLY_PGCONFIG_PARAMETERS: $APPLY_PGCONFIG_PARAMETERS"
	echo "PURGE_OLD_EXTERNAL_DATA: $PURGE_OLD_EXTERNAL_DATA"
	echo "KILL_PREVIOUS_PROCESSES: $KILL_PREVIOUS_PROCESSES"
	echo "############################################################################"
	echo ""
}

# True if $1 is this process or an ancestor of this process (must not be killed).
_tpcds_is_self_or_ancestor()
{
	local target=$1
	local cur=$$
	while [ -n "$cur" ] && [ "$cur" -gt 1 ]; do
		if [ "$cur" = "$target" ]; then
			return 0
		fi
		cur=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
	done
	return 1
}

# TERM/KILL a process and its descendants (children first).
_tpcds_kill_tree()
{
	local pid=$1
	local sig=${2:-TERM}
	local child
	for child in $(pgrep -P "$pid" 2>/dev/null); do
		_tpcds_kill_tree "$child" "$sig"
	done
	if kill -0 "$pid" 2>/dev/null || run_priv kill -0 "$pid" 2>/dev/null; then
		echo "  kill -$sig $pid: $(ps -p "$pid" -o args= 2>/dev/null | head -c 160)"
		kill "-$sig" "$pid" 2>/dev/null || run_priv kill "-$sig" "$pid" 2>/dev/null || true
	fi
}

# Stop leftover TPC runs for BOTH TPC-DS and TPC-H
# (tpc.sh / rollout / test.sh / dsdgen / dsqgen / dbgen / qgen / generate_*.sh / gpfdist / psql).
# Does not touch the current entry script ($$) or its ancestors. Called before this run starts rollout.
kill_previous_processes()
{
	local repo self pid candidates
	local found=0

	if [ "${KILL_PREVIOUS_PROCESSES:-true}" != "true" ]; then
		echo "KILL_PREVIOUS_PROCESSES=false: leaving existing TPC processes alone"
		return 0
	fi

	self=$$
	repo="$PWD"
	echo "KILL_PREVIOUS_PROCESSES=true: searching for leftover TPC-DS and TPC-H processes (excluding pid $self)..."

	candidates=$(
		{
			# Entry / top-level rollout
			pgrep -f "${repo}/tpc\\.sh" 2>/dev/null || true
			pgrep -f "${repo}/rollout\\.sh" 2>/dev/null || true
			pgrep -f "/tpc\\.sh" 2>/dev/null || true
			pgrep -f "[.]/tpc\\.sh" 2>/dev/null || true

			# Any step script under either suite (rollout, test, generate_*, compile, …)
			pgrep -f "${repo}/tpcds/" 2>/dev/null || true
			pgrep -f "${repo}/tpch/" 2>/dev/null || true

			# Multi-user sessions
			pgrep -f "${repo}/tpcds/07_multi_user/" 2>/dev/null || true
			pgrep -f "${repo}/tpch/07_multi_user/" 2>/dev/null || true

			# Generators: may run from repo OR from \$HOME after scp to segments
			pgrep -f "(^|/)dsqgen( |$)" 2>/dev/null || true
			pgrep -f "(^|/)dsdgen( |$)" 2>/dev/null || true
			pgrep -f "(^|/)dbgen( |$)" 2>/dev/null || true
			pgrep -f "(^|/)qgen( |$)" 2>/dev/null || true
			pgrep -f "generate_data\\.sh" 2>/dev/null || true
			pgrep -f "generate_queries\\.sh" 2>/dev/null || true

			# Greenplum load helper (both suites)
			pgrep -f "(^|/)gpfdist( |$)" 2>/dev/null || true
			pgrep -f "start_gpfdist\\.sh" 2>/dev/null || true

			# psql running SQL from either suite
			pgrep -f "psql .*-f ${repo}/tpcds/" 2>/dev/null || true
			pgrep -f "psql .*-f ${repo}/tpch/" 2>/dev/null || true
			pgrep -f "psql .*-f ${repo}/" 2>/dev/null || true

			# How rollout is launched from tpc.sh
			pgrep -f "su -l .*${repo}.*rollout\\.sh" 2>/dev/null || true
			pgrep -f "sudo .*-u .*${repo}.*rollout\\.sh" 2>/dev/null || true
			pgrep -f "bash -lc .*${repo}.*rollout\\.sh" 2>/dev/null || true
		} | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u
	)

	for pid in $candidates; do
		if _tpcds_is_self_or_ancestor "$pid"; then
			continue
		fi
		found=1
		_tpcds_kill_tree "$pid" TERM
	done

	if [ "$found" -eq 0 ]; then
		echo "  (no leftover TPC processes found)"
	else
		sleep 2

		for pid in $candidates; do
			if _tpcds_is_self_or_ancestor "$pid"; then
				continue
			fi
			if kill -0 "$pid" 2>/dev/null || run_priv kill -0 "$pid" 2>/dev/null; then
				_tpcds_kill_tree "$pid" KILL
			fi
		done
	fi

	# Terminate leftover client backends in the current DB and common DS/H database names.
	if command -v psql >/dev/null 2>&1 && [ -n "${ADMIN_USER:-}" ]; then
		local dbs
		dbs=$(printf '%s\n' "${DBNAME:-}" "pg_tpc" "pg_tpcds" "pg_tpch" "gp_tpcds" "gp_tpch" | awk 'NF && !seen[$0]++' | paste -sd, -)
		echo "Terminating leftover client backends in databases: $dbs ..."
		as_admin "psql -d postgres -v ON_ERROR_STOP=0 -q -c \"
SELECT pg_terminate_backend(pid) AS terminated, datname, pid, left(query, 80) AS query
FROM pg_stat_activity
WHERE datname = ANY(string_to_array('$dbs', ','))
  AND pid <> pg_backend_pid()
  AND backend_type = 'client backend';
\"" 2>/dev/null || true
		sleep 1
	fi

	echo "Done killing leftover TPC-DS / TPC-H processes."
}

# Hostnames for cluster-wide OS tweaks (jumbo frames).
cluster_host_list()
{
	local hosts_file="/home/${ADMIN_USER}/arenadata_configs/arenadata_all_hosts.hosts"
	local hosts
	if hosts=$(as_admin "test -r \"$hosts_file\" && cat \"$hosts_file\"") && [ -n "$hosts" ]; then
		printf '%s\n' "$hosts"
		return 0
	fi
	if hosts=$(as_admin "psql -d postgres -v ON_ERROR_STOP=1 -tAc \"SELECT DISTINCT hostname FROM gp_segment_configuration ORDER BY 1\"") && [ -n "$hosts" ]; then
		printf '%s\n' "$hosts"
		return 0
	fi
	return 1
}

make_prerequisites()
{
	local iface="${NETWORK_INTERFACE_JUMBOFRAME}"
	local host out failed=0 hosts

	case "$iface" in
		""|*[!a-zA-Z0-9._-]*)
			echo "ERROR: NETWORK_INTERFACE_JUMBOFRAME='${iface}' is empty or invalid"
			exit 1
			;;
	esac

	if ! hosts=$(cluster_host_list); then
		echo "ERROR: cannot list cluster hosts (arenadata_all_hosts.hosts / gp_segment_configuration)."
		exit 1
	fi

	echo "Setting mtu 9000 on ${iface} on all hosts..."

	# gpssh + sudo hangs forever on a password prompt (nohup has no TTY).
	# BatchMode ssh + sudo -n fail immediately if SSH keys or NOPASSWD sudo are missing.
	while IFS= read -r host || [ -n "$host" ]; do
		host=$(echo "$host" | tr -d '[:space:]')
		[ -z "$host" ] && continue
		echo "  $host:"
		if ! out=$(as_admin "ssh -n -o BatchMode=yes -o ConnectTimeout=10 \"$host\" \"sudo -n ip link set mtu 9000 dev $iface && ip -o link show $iface\"" 2>&1); then
			echo "ERROR: cannot set mtu 9000 on $host ($iface)."
			echo "$out"
			echo "SSH as $ADMIN_USER to $host is not enough: passwordless sudo is required there"
			echo "  (sudo -n ip link set mtu 9000 dev $iface)."
			failed=1
		else
			echo "$out"
		fi
	done <<< "$hosts"

	if [ "$failed" -ne 0 ]; then
		echo "ERROR: jumbo frames (mtu 9000) were not applied on all hosts."
		echo "Ensure $ADMIN_USER has NOPASSWD sudo on the hosts above, or set MAKE_PREREQUISITES=false."
		exit 1
	fi

	echo "Checking if cluster is started..."
	IS_CLUSTER_STARTED=$(as_admin "gpstate -e | grep 'All segments are running normally'" | wc -l)
	echo "IS_CLUSTER_STARTED = $IS_CLUSTER_STARTED"

	if [[ "$IS_CLUSTER_STARTED" == "0" ]]; then
		echo "Cluster is stopped. Starting the cluster..."
		echo "gpstart -a"
		as_admin "gpstart -a"
	fi
}

run_after_rollout()
{
	#echo "Starting crond..."
	#systemctl start crond
	echo "Finish."
}

archive_tpcds_log()
{
	local format="heap"
	local duck_suffix=""
	local ts dest src log_dir prefix

	case "${USE_EXTERNAL_FORMAT}" in
		parquet|csv|json) format="$USE_EXTERNAL_FORMAT" ;;
	esac
	if [ "${RUN_SQL_WITH_DUCKDB}" = "true" ]; then
		duck_suffix="_with-duckdb"
	fi

	prefix="${TPC_LOG_PREFIX:-tpcds}"
	log_dir="$PWD/log/archived_results"
	mkdir -p "$log_dir"
	ts=$(date +%Y%m%d_%H%M%S)
	dest="$log_dir/${ts}_${prefix}_SF${GEN_DATA_SCALE}_${format}${duck_suffix}.log"

	src=""
	if [ -f "$PWD/tpc.log" ]; then
		src="$PWD/tpc.log"
	elif [ -f "./tpc.log" ]; then
		src="./tpc.log"
	elif [ -f "$PWD/tpcds.log" ]; then
		src="$PWD/tpcds.log"
	elif [ -f "./tpcds.log" ]; then
		src="./tpcds.log"
	fi

	if [ -n "$src" ]; then
		cp -a "$src" "$dest"
		echo "Archived run log: $dest"
	else
		echo "WARNING: tpc.log not found; skipped archive copy"
	fi
}


##################################################################################################################################################
# Body
##################################################################################################################################################

check_user
check_variables
yum_installs
# Переключает репозиторий на ветку REPO_BRANCH из tpc_variables.sh
repo_init
require_admin_can_enter_clone
# Resolve TPC_MODE → schemas / step roots / log prefixes
source "$PWD/mode.sh"
init_tpc_mode
echo_variables
echo "TPC_MODE: $TPC_MODE"
kill_previous_processes

if [ "$MAKE_PREREQUISITES" == "true" ]; then
	echo "Running make_prerequisites step"
        make_prerequisites
fi


as_admin "cd \"$PWD\"; PGPORT_WRITE=\"${PGPORT_WRITE:-5432}\" PGPORT_SELECT=\"${PGPORT_SELECT:-5432}\" PGPORT=\"${PGPORT_WRITE:-5432}\" PGHOST=\"${PGHOST:-}\" APPLY_PGCONFIG_PARAMETERS=\"${APPLY_PGCONFIG_PARAMETERS:-false}\" ./rollout.sh $GEN_DATA_SCALE $EXPLAIN_ANALYZE $RANDOM_DISTRIBUTION $MULTI_USER_COUNT $RUN_COMPILE_TPC $RUN_GEN_DATA $RUN_INIT $RUN_DDL $RUN_LOAD $RUN_SQL $RUN_SINGLE_USER_REPORT $RUN_MULTI_USER $RUN_MULTI_USER_REPORT $RUN_SCORE $SINGLE_USER_ITERATIONS $PARTITION_EVERY_FACTOR $EXCLUDE_HEAVY_QUERIES $EMPTY_SCHEMAS_CNT $TRUNCATE_BEFORE_LOAD $SQL_ON_ERROR_STOP $net_core_rmem $net_core_wmem $rg6_memory_limit $rg6_memory_shared_quota $rg6_concurrency $rg6_cpu_rate_limit $rg7_cpu_hard_quota_limit $DELETE_DAT_FILES_BEFORE_SQL $RUN_SQL_FROM_ROLE $REFERENCE_TABLE_TYPE $DROP_CACHE_BEFORE_SQL $HEAP_ONLY $ADMIN_USER $MAKE_PREREQUISITES $NETWORK_INTERFACE_JUMBOFRAME $SET_ORCA_OPTIMIZER $DBNAME $STATEMENT_TIMEOUT $USE_EXTERNAL_FORMAT $EXTERNAL_HIVE_PARTITIONING $EXTERNAL_FILE_SIZE_BYTES $EXTERNAL_COMPRESSION $RUN_SQL_WITH_DUCKDB $PURGE_OLD_EXTERNAL_DATA $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN $COLLECT_OS_DATA \"$COLLECT_DATA_PERIOD\" \"$SKIP_QUERIES_LIST\" \"$TPC_MODE\" \"$DAT_FILE_SUBDIRECTORY_NAME\" \"$EXTERNAL_FILE_DIRECTORY_PATH\""

# Final marker for tpc.log / tail -f (printed only after rollout returns successfully;
# independent of which RUN_* steps were enabled).
echo ""
echo "The end. All ${TPC_BENCH_LABEL} steps completed"

# Keep rewriting tpc.log each run; also archive a timestamped copy under log/archived_results/.
archive_tpcds_log

