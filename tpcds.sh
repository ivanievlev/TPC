#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

MYCMD="tpcds.sh"
MYVAR="tpcds_variables.sh"
##################################################################################################################################################
# Functions
##################################################################################################################################################
check_variables()
{
	new_variable="0"

	### Make sure variables file is available
	if [ ! -f "$PWD/$MYVAR" ]; then
		touch $PWD/$MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "REPO=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "REPO=\"TPC-DS\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "REPO_URL=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "REPO_URL=\"https://github.com/ivanievlev/TPC-DS\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "REPO_BRANCH=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "REPO_BRANCH=\"master\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "ADMIN_USER=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "ADMIN_USER=\"gpadmin\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
        local count=$(grep "DBNAME=" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "DBNAME=\"gp_tpcds\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi
	local count=$(grep "INSTALL_DIR=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "INSTALL_DIR=\"/arenadata\"" >> $MYVAR
		new_variable=$(($new_variable + 1))
	fi
	local count=$(grep "EXPLAIN_ANALYZE=" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "EXPLAIN_ANALYZE=\"false\"" >> $MYVAR
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
        local count=$(grep "EXTRA_TPCDS_SCHEMAS" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "EXTRA_TPCDS_SCHEMAS=\"0\"" >> $MYVAR
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
	local count=$(grep "RUN_COMPILE_TPCDS" $MYVAR | wc -l)
	if [ "$count" -eq "0" ]; then
		echo "RUN_COMPILE_TPCDS=\"false\"" >> $MYVAR
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
                echo "RUN_SQL_FROM_ROLE=\"gpadmin\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

        local count=$(grep "REFERENCE_TABLE_TYPE" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "REFERENCE_TABLE_TYPE=\"aoco\"" >> $MYVAR
                new_variable=$(($new_variable + 1))
        fi

	local count=$(grep "DROP_CACHE_BEFORE_EACH_SINGLE_QUERY" $MYVAR | wc -l)
        if [ "$count" -eq "0" ]; then
                echo "DROP_CACHE_BEFORE_EACH_SINGLE_QUERY=\"false\"" >> $MYVAR
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

	if [ "$new_variable" -gt "0" ]; then
		echo "There are new variables in the tpcds_variables.sh file.  Please review to ensure the values are correct and then re-run this script."
		exit 1
	fi
	echo "############################################################################"
	echo "Sourcing $MYVAR"
	echo "############################################################################"
	echo ""
	source $MYVAR
	if [ -z "${SKIP_QUERIES_LIST+x}" ]; then
		SKIP_QUERIES_LIST=""
	fi
	# Inline validation (tpcds.sh does not source functions.sh — avoid clobbering ADMIN_USER).
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
	### Make sure root is executing the script. ###
	echo "############################################################################"
	echo "Make sure root is executing this script."
	echo "############################################################################"
	echo ""
	local WHOAMI=`whoami`
	if [ "$WHOAMI" != "root" ]; then
		echo "Script must be executed as root!"
		exit 1
	fi
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
			yum -y install gcc
		fi
		if [ "$GIT_INSTALLED" -eq "0" ]; then
			yum -y install git
		fi
		if [ "$BC_INSTALLED" -eq "0" ]; then
			yum -y install bc
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

repo_init()
{
	### Install repo ###
	echo "############################################################################"
	echo "Install the github repository."
	echo "############################################################################"
	echo ""

	internet_down="0"
	for j in $(curl google.com 2>&1 | grep "Couldn't resolve host"); do
		internet_down="1"
	done

	if [ ! -d $INSTALL_DIR ]; then
		if [ "$internet_down" -eq "1" ]; then
			echo "Unable to continue because repo hasn't been downloaded and Internet is not available."
			exit 1
		else
			echo ""
			echo "Creating install dir"
			echo "-------------------------------------------------------------------------"
			mkdir $INSTALL_DIR
			chown $ADMIN_USER $INSTALL_DIR
		fi
	fi

	# REPO_BRANCH задаётся в tpcds_variables.sh (по умолчанию master)
	if [ -z "$REPO_BRANCH" ]; then
		REPO_BRANCH="master"
	fi

	if [ ! -d $INSTALL_DIR/$REPO ]; then
		if [ "$internet_down" -eq "1" ]; then
			echo "Unable to continue because repo hasn't been downloaded and Internet is not available."
			exit 1
		else
			echo ""
			echo "Creating $REPO directory (branch: $REPO_BRANCH)"
			echo "-------------------------------------------------------------------------"
			mkdir $INSTALL_DIR/$REPO
			chown $ADMIN_USER $INSTALL_DIR/$REPO
			su -c "cd $INSTALL_DIR; GIT_SSL_NO_VERIFY=true git clone --depth=1 -b $REPO_BRANCH $REPO_URL" $ADMIN_USER
		fi
	else
		chown -R $ADMIN_USER $INSTALL_DIR/$REPO

		# Не сбрасываем локальные коммиты (никакого reset --hard / checkout -B origin/...).
		# 1) при грязном дереве — стоп; 2) иначе checkout локальной REPO_BRANCH;
		# 3) если локальной ветки нет — создать от origin/REPO_BRANCH.
		local dirty
		dirty=$(su -c "cd \"$INSTALL_DIR/$REPO\" && git status --porcelain" $ADMIN_USER 2>/dev/null | wc -l)
		if [ "$dirty" -gt "0" ]; then
			echo "ERROR: repository $INSTALL_DIR/$REPO has uncommitted changes."
			echo "Please commit (or stash) them before running tpcds.sh, then re-run."
			echo ""
			su -c "cd \"$INSTALL_DIR/$REPO\" && git status --short" $ADMIN_USER || true
			exit 1
		fi

		if [ "$internet_down" -eq "0" ]; then
			su -c "cd \"$INSTALL_DIR/$REPO\"; GIT_SSL_NO_VERIFY=true git fetch origin $REPO_BRANCH || true" $ADMIN_USER || true
		fi

		su -c "cd \"$INSTALL_DIR/$REPO\"; \
			if git rev-parse --verify $REPO_BRANCH >/dev/null 2>&1; then \
				echo \"Checking out local branch $REPO_BRANCH (keeping local commits)\"; \
				git checkout $REPO_BRANCH; \
			elif git rev-parse --verify origin/$REPO_BRANCH >/dev/null 2>&1; then \
				echo \"Local branch $REPO_BRANCH missing; creating from origin/$REPO_BRANCH\"; \
				git checkout -b $REPO_BRANCH origin/$REPO_BRANCH; \
			else \
				echo \"ERROR: branch $REPO_BRANCH not found locally or on origin\"; \
				exit 1; \
			fi; \
			echo \"Now on branch: \$(git rev-parse --abbrev-ref HEAD) @ \$(git rev-parse --short HEAD)\"" $ADMIN_USER
	fi
}

script_check()
{
	### Make sure the repo doesn't have a newer version of this script. ###
	echo "############################################################################"
	echo "Make sure this script is up to date."
	echo "############################################################################"
	echo ""
	# Must be executed after the repo has been pulled
	local d=`diff $PWD/$MYCMD $INSTALL_DIR/$REPO/$MYCMD | wc -l`

	if [ "$d" -eq "0" ]; then
		echo "$MYCMD script is up to date so continuing to TPC-DS."
		echo ""
	else
		echo "$MYCMD script is NOT up to date."
		echo ""
		cp $INSTALL_DIR/$REPO/$MYCMD $PWD/$MYCMD
		echo "After this script completes, restart the $MYCMD with this command:"
		echo "./$MYCMD"
		exit 1
	fi

}

echo_variables()
{
	echo "############################################################################"
	echo "REPO: $REPO"
	echo "REPO_URL: $REPO_URL"
	echo "REPO_BRANCH: $REPO_BRANCH"
	echo "ADMIN_USER: $ADMIN_USER"
	echo "DBNAME: $DBNAME"
	echo "INSTALL_DIR: $INSTALL_DIR"
	echo "MULTI_USER_COUNT: $MULTI_USER_COUNT"
	echo "PARTITION_EVERY_FACTOR: $PARTITION_EVERY_FACTOR"
	echo "EXCLUDE_HEAVY_QUERIES: $EXCLUDE_HEAVY_QUERIES"
	echo "SKIP_QUERIES_LIST: $SKIP_QUERIES_LIST"
        echo "EXTRA_TPCDS_SCHEMAS: $EXTRA_TPCDS_SCHEMAS"
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
	echo "DROP_CACHE_BEFORE_EACH_SINGLE_QUERY: $DROP_CACHE_BEFORE_EACH_SINGLE_QUERY"
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
	if kill -0 "$pid" 2>/dev/null; then
		echo "  kill -$sig $pid: $(ps -p "$pid" -o args= 2>/dev/null | head -c 160)"
		kill "-$sig" "$pid" 2>/dev/null || true
	fi
}

# Stop leftover TPC-DS runs (previous tpcds.sh / rollout / test.sh / dsqgen / psql -f .../TPC-DS).
# Does not touch the current tpcds.sh ($$) or its ancestors. Called before this run starts rollout.
kill_previous_processes()
{
	local repo self pid candidates
	local found=0

	if [ "${KILL_PREVIOUS_PROCESSES:-true}" != "true" ]; then
		echo "KILL_PREVIOUS_PROCESSES=false: leaving existing TPC-DS processes alone"
		return 0
	fi

	self=$$
	repo="${INSTALL_DIR}/${REPO}"
	echo "KILL_PREVIOUS_PROCESSES=true: searching for leftover TPC-DS processes (excluding pid $self)..."

	candidates=$(
		{
			pgrep -f "${repo}/tpcds\\.sh" 2>/dev/null || true
			pgrep -f "${repo}/rollout\\.sh" 2>/dev/null || true
			pgrep -f "${repo}/[0-9][^ ]*/rollout\\.sh" 2>/dev/null || true
			pgrep -f "${repo}/07_multi_user/test\\.sh" 2>/dev/null || true
			pgrep -f "${repo}/[^ ]*dsqgen" 2>/dev/null || true
			pgrep -f "/tpcds\\.sh" 2>/dev/null || true
			pgrep -f "[.]/tpcds\\.sh" 2>/dev/null || true
			pgrep -f "psql .*-f ${repo}/" 2>/dev/null || true
			pgrep -f "su -l .*${repo}.*rollout\\.sh" 2>/dev/null || true
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
		echo "  (no leftover TPC-DS processes found)"
		return 0
	fi

	sleep 2

	for pid in $candidates; do
		if _tpcds_is_self_or_ancestor "$pid"; then
			continue
		fi
		if kill -0 "$pid" 2>/dev/null; then
			_tpcds_kill_tree "$pid" KILL
		fi
	done

	# Terminate leftover client backends in DBNAME (orphan queries hold locks after
	# clients are killed; DROP SCHEMA / DDL would hang otherwise). Safe for a
	# dedicated benchmark database — does not use kill -9 on postgres processes.
	if command -v psql >/dev/null 2>&1 && [ -n "${DBNAME:-}" ] && [ -n "${ADMIN_USER:-}" ]; then
		echo "Terminating leftover client backends in database $DBNAME..."
		su -l "$ADMIN_USER" -c "psql -d \"$DBNAME\" -v ON_ERROR_STOP=0 -q -c \"
SELECT pg_terminate_backend(pid) AS terminated, pid, left(query, 80) AS query
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
  AND backend_type = 'client backend';
\"" 2>/dev/null || true
		sleep 1
	fi

	echo "Done killing leftover TPC-DS processes."
}

make_prerequisites()
{
	
	echo "Setting mtu 9000 on all hosts..."
	su -l $ADMIN_USER -c "gpssh -f /home/gpadmin/arenadata_configs/arenadata_all_hosts.hosts -v -e 'sudo ip link set mtu 9000 dev $NETWORK_INTERFACE_JUMBOFRAME'"

	echo "Checking if cluster is started..."
	IS_CLUSTER_STARTED=$(su -l "$ADMIN_USER" -c "gpstate -e | grep 'All segments are running normally'" | wc -l)
        echo "IS_CLUSTER_STARTED = $IS_CLUSTER_STARTED"

        if [[ "$IS_CLUSTER_STARTED" == "0" ]]; then

                echo "Cluster is stopped. Starting the cluster..."
		echo "gpstart -a"
                su -l $ADMIN_USER -c "gpstart -a"
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
	local ts dest src log_dir

	case "${USE_EXTERNAL_FORMAT}" in
		parquet|csv|json) format="$USE_EXTERNAL_FORMAT" ;;
	esac
	if [ "${RUN_SQL_WITH_DUCKDB}" = "true" ]; then
		duck_suffix="_with-duckdb"
	fi

	log_dir="$INSTALL_DIR/$REPO/log"
	mkdir -p "$log_dir"
	ts=$(date +%Y%m%d_%H%M%S)
	dest="$log_dir/tpcds_SF${GEN_DATA_SCALE}_${format}${duck_suffix}_${ts}.log"

	src=""
	if [ -f "$INSTALL_DIR/$REPO/tpcds.log" ]; then
		src="$INSTALL_DIR/$REPO/tpcds.log"
	elif [ -f "./tpcds.log" ]; then
		src="./tpcds.log"
	fi

	if [ -n "$src" ]; then
		cp -a "$src" "$dest"
		echo "Archived run log: $dest"
	else
		echo "WARNING: tpcds.log not found; skipped archive copy"
	fi
}


##################################################################################################################################################
# Body
##################################################################################################################################################

check_user
check_variables
yum_installs
# Переключает репозиторий на ветку REPO_BRANCH из tpcds_variables.sh
repo_init
script_check
echo_variables
kill_previous_processes

if [ "$MAKE_PREREQUISITES" == "true" ]; then
	echo "Running make_prerequisites step"
        make_prerequisites
fi


su -l $ADMIN_USER -c "cd \"$INSTALL_DIR/$REPO\"; ./rollout.sh $GEN_DATA_SCALE $EXPLAIN_ANALYZE $RANDOM_DISTRIBUTION $MULTI_USER_COUNT $RUN_COMPILE_TPCDS $RUN_GEN_DATA $RUN_INIT $RUN_DDL $RUN_LOAD $RUN_SQL $RUN_SINGLE_USER_REPORT $RUN_MULTI_USER $RUN_MULTI_USER_REPORT $RUN_SCORE $SINGLE_USER_ITERATIONS $PARTITION_EVERY_FACTOR $EXCLUDE_HEAVY_QUERIES $EXTRA_TPCDS_SCHEMAS $TRUNCATE_BEFORE_LOAD $SQL_ON_ERROR_STOP $net_core_rmem $net_core_wmem $rg6_memory_limit $rg6_memory_shared_quota $rg6_concurrency $rg6_cpu_rate_limit $rg7_cpu_hard_quota_limit $DELETE_DAT_FILES_BEFORE_SQL $RUN_SQL_FROM_ROLE $REFERENCE_TABLE_TYPE $DROP_CACHE_BEFORE_EACH_SINGLE_QUERY $HEAP_ONLY $ADMIN_USER $MAKE_PREREQUISITES $NETWORK_INTERFACE_JUMBOFRAME $SET_ORCA_OPTIMIZER $DBNAME $STATEMENT_TIMEOUT $USE_EXTERNAL_FORMAT $EXTERNAL_HIVE_PARTITIONING $EXTERNAL_FILE_SIZE_BYTES $EXTERNAL_COMPRESSION $RUN_SQL_WITH_DUCKDB $PURGE_OLD_EXTERNAL_DATA $DUCKDB_MEMORY_LIMIT $DUCKDB_THREADS $DUCKDB_MAX_WORKERS_PER_POSTGRES_SCAN $DUCKDB_THREADS_FOR_POSTGRES_SCAN \"$SKIP_QUERIES_LIST\""

# Final marker for tpcds.log / tail -f (printed only after rollout returns successfully;
# independent of which RUN_* steps were enabled).
echo ""
echo "The end. All TPC-DS steps completed"

# Keep rewriting tpcds.log each run; also archive a timestamped copy under log/.
archive_tpcds_log

