#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
net_core_rmem=${11}
net_core_wmem=${12}
rg6_memory_limit=${13}
rg6_memory_shared_quota=${14}
rg6_concurrency=${15}
rg6_cpu_rate_limit=${16}
rg7_cpu_hard_quota_limit=${17}
RUN_SQL_FROM_ROLE=${19}
ADMIN_USER=${22}
SET_OPTIMIZER=${25}
DBNAME=${27}

echo "DBNAME=$DBNAME"
IS_DB_EXIST=$(psql -d postgres -v ON_ERROR_STOP=1 -q -A -t -c "select count(*) from pg_database where datname = '$DBNAME'")
echo "IS_DB_EXIST = $IS_DB_EXIST"

if [[ "$IS_DB_EXIST" == "0" ]]; then
        psql -d postgres -c "create database $DBNAME"

fi


step=init
init_log $step
start_log
schema_name="tpcds"
table_name="init"

set_segment_bashrc()
{
	#this is only needed if the segment hosts don't have the bashrc file created
	echo "if [ -f /etc/bashrc ]; then" > $PWD/segment_bashrc
	echo "	. /etc/bashrc" >> $PWD/segment_bashrc
	echo "fi" >> $PWD/segment_bashrc
	echo "source /usr/local/greenplum-db/greenplum_path.sh" >> $PWD/segment_bashrc
	
	#LD_PRELOAD=/lib64/libz.so.1 ps is optional and it caused problems on Astra Linux
	#echo "export LD_PRELOAD=/lib64/libz.so.1 ps" >> $PWD/segment_bashrc
	chmod 755 $PWD/segment_bashrc

	#copy generate_data.sh to ~/
	for ext_host in $(cat $PWD/../../segment_hosts.txt); do
		# don't overwrite the master.  Only needed on single node installs
		shortname=$(echo $ext_host | awk -F '.' '{print $1}')
		if [ "$MASTER_HOST" != "$shortname" ]; then
			bashrc_exists=$(ssh $ext_host "ls ~/.bashrc" 2> /dev/null | wc -l)
			if [ "$bashrc_exists" -eq "0" ]; then
				echo "copy new .bashrc to $ext_host:$ADMIN_HOME"
				scp $PWD/segment_bashrc $ext_host:$ADMIN_HOME/.bashrc
			else
				count=$(ssh $ext_host "grep greenplum_path ~/.bashrc" 2> /dev/null | wc -l)
				if [ "$count" -eq "0" ]; then
					echo "Adding greenplum_path to $ext_host .bashrc"
					ssh $ext_host "echo \"source $GREENPLUM_PATH\" >> ~/.bashrc"
				fi
				count=$(ssh $ext_host "grep LD_PRELOAD ~/.bashrc" 2> /dev/null | wc -l)
				if [ "$count" -eq "0" ]; then
					echo "Adding LD_PRELOAD to $ext_host .bashrc"
					#ssh $ext_host "echo \"export LD_PRELOAD=/lib64/libz.so.1 ps\" >> ~/.bashrc"
				fi
			fi
		fi
	done
}
check_gucs()
{
	update_config="0"

	if [ "$VERSION" == "gpdb_5" ]; then
		counter=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "show optimizer_join_arity_for_associativity_commutativity" | grep -i "18" | wc -l; exit ${PIPESTATUS[0]})
		if [ "$counter" -eq "0" ]; then
			echo "setting optimizer_join_arity_for_associativity_commutativity"
			gpconfig -c optimizer_join_arity_for_associativity_commutativity -v 18 --skipvalidation
			update_config="1"
		fi
	fi

	echo "check optimizer"
	counter=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "show optimizer" | grep -i "on" | wc -l; exit ${PIPESTATUS[0]})

	if [ "$counter" -eq "0" ]; then
		echo "enabling optimizer"
		gpconfig -c optimizer -v on --masteronly
		update_config="1"
	fi

	echo "check analyze_root_partition"
	counter=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "show optimizer_analyze_root_partition" | grep -i "on" | wc -l; exit ${PIPESTATUS[0]})
	if [ "$counter" -eq "0" ]; then
		echo "enabling analyze_root_partition"
		gpconfig -c optimizer_analyze_root_partition -v on --masteronly
		update_config="1"
	fi

	echo "check gp_autostats_mode"
	counter=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "show gp_autostats_mode" | grep -i "none" | wc -l; exit ${PIPESTATUS[0]})
	if [ "$counter" -eq "0" ]; then
		echo "changing gp_autostats_mode to none"
		gpconfig -c gp_autostats_mode -v none --masteronly
		update_config="1"
	fi

	echo "check default_statistics_target"
	counter=$(psql -d $DBNAME -v ON_ERROR_STOP=1 -q -t -A -c "show default_statistics_target" | grep "100" | wc -l; exit ${PIPESTATUS[0]})
	if [ "$counter" -eq "0" ]; then
		echo "changing default_statistics_target to 100"
		gpconfig -c default_statistics_target -v 100
		update_config="1"
	fi

	if [ "$update_config" -eq "1" ]; then
		echo "update cluster because of config changes"
		gpstop -u
	fi
}
copy_config()
{
	echo "copy config files"
	if [ "$MASTER_DATA_DIRECTORY" != "" ]; then
		cp $MASTER_DATA_DIRECTORY/pg_hba.conf $PWD/../../log/
		cp $MASTER_DATA_DIRECTORY/postgresql.conf $PWD/../../log/
	fi
	#gp_segment_configuration
	psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "SELECT * FROM gp_segment_configuration" -o $PWD/../../log/gp_segment_configuration.txt
}
set_search_path()
{
	#echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"ALTER USER $USER SET search_path=$schema_name,public;\""
	#psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER USER $USER SET search_path=$schema_name,public;"
	echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"ALTER DATABASE $DBNAME SET search_path=$schema_name,public;\""
        psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER DATABASE $DBNAME SET search_path=$schema_name,public;"
}

set_adcc_superuser()
{
	IS_ROLE_EXIST=$(psql -d postgres -v ON_ERROR_STOP=1 -q -A -t -c "select count(*) from pg_roles where rolname = 'adcc'")
	echo "IS_ROLE_EXIST = $IS_ROLE_EXIST"

	if [[ "$IS_ROLE_EXIST" == "0" ]]; then

        	echo "psql -d $DBNAME -v ON_ERROR_STOP=0 -q -A -t -c \"create role adcc\""
        	psql -d $DBNAME -v ON_ERROR_STOP=0 -q -A -t -c "create role adcc;"
	fi
        
	echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"alter role adcc superuser\""
        psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "alter role adcc superuser;"
}


create_run_sql_from_role()
{
        IS_ROLE_EXIST=$(psql -d postgres -v ON_ERROR_STOP=1 -q -A -t -c "select count(*) from pg_roles where rolname = '$RUN_SQL_FROM_ROLE'")
        echo "IS_ROLE_EXIST = $IS_ROLE_EXIST"

        if [[ "$IS_ROLE_EXIST" == "0" ]]; then

                echo "psql -d $DBNAME -v ON_ERROR_STOP=0 -q -A -t -c \"create role $RUN_SQL_FROM_ROLE SUPERUSER login\""
                psql -d $DBNAME -v ON_ERROR_STOP=0 -q -A -t -c "create role $RUN_SQL_FROM_ROLE SUPERUSER login;"
                #echo "psql -d $DBNAME -v ON_ERROR_STOP=0 -q -A -t -c \"grant usage on schema to tpcds $RUN_SQL_FROM_ROLE\""
                #psql -d $DBNAME -v ON_ERROR_STOP=0 -q -A -t -c "grant usage on schema tpcds to $RUN_SQL_FROM_ROLE;"
                echo "psql -d $DBNAME -v ON_ERROR_STOP=0 -q -A -t -c \"alter role $RUN_SQL_FROM_ROLE IN DATABASE $DBNAME SET search_path TO tpcds\""
                psql -d $DBNAME -v ON_ERROR_STOP=0 -q -A -t -c "alter role $RUN_SQL_FROM_ROLE IN DATABASE $DBNAME SET search_path TO tpcds;"


	fi

        echo "Checking if sql users have access to cluster..."
	echo "ADMIN_USER = $ADMIN_USER"
        HAS_ACCESS=$(psql -d "$DBNAME" -U "$RUN_SQL_FROM_ROLE" -v ON_ERROR_STOP=1 -q -A -t -c 'select 1' | wc -l)
        echo "HAS_ACCESS = $HAS_ACCESS"

        if [[ "$HAS_ACCESS" == "0" ]]; then

                echo "User has no access. Adding line to pg_hba..."
                echo "local all all trust" >> /data1/master/gpseg-1/pg_hba.conf
                gpstop -u
        fi


}



#added set memory_limit and memory_shared_quota because with EVERY=1 too much partitions caused Canceling query 020.gpdb.web_returns.sql because of high VMEM usage
set_workfile_limits()
{
	echo "gpconfig -c gp_workfile_limit_per_query -v 0"
	gpconfig -c gp_workfile_limit_per_query -v 0
        echo "gpconfig -c gp_workfile_limit_per_segment -v 0"
        gpconfig -c gp_workfile_limit_per_segment -v 0
        echo "gpconfig -c gp_workfile_limit_files_per_query -v 0"
        gpconfig -c gp_workfile_limit_files_per_query -v 0
        echo "gpstop -r"
        gpstop -aqrM fast
}


set_optimizer()
{
	echo "gpconfig -c optimizer -v $SET_OPTIMIZER --masteronly"
	gpconfig -c optimizer -v $SET_OPTIMIZER --masteronly
	gpstop -u
}

set_net_core_mem()
{
	echo "sysctl -w net.core.rmem_max=$net_core_rmem"
	sudo sysctl -w net.core.rmem_max=$net_core_rmem
	echo "sysctl -w net.core.rmem_default=$net_core_rmem"
	sudo sysctl -w net.core.rmem_default=$net_core_rmem
	echo "sysctl -w net.core.wmem_max=$net_core_wmem"
	sudo sysctl -w net.core.wmem_max=$net_core_wmem
	echo "sysctl -w net.core.wmem_default=$net_core_wmem"
	sudo sysctl -w net.core.wmem_default=$net_core_wmem
}

get_version
if [[ "$VERSION" == *"gpdb"* ]]; then
	#set_segment_bashrc
	check_gucs
	copy_config
  set_adcc_superuser
  set_optimizer



	
	if [[ "$VERSION" == "gpdb_6" ]]; then
        	echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"ALTER RESOURCE GROUP admin_group SET MEMORY_LIMIT $rg6_memory_limit;\""
        	psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER RESOURCE GROUP admin_group SET MEMORY_LIMIT $rg6_memory_limit;"
		echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"ALTER RESOURCE GROUP admin_group SET MEMORY_SHARED_QUOTA $rg6_memory_shared_quota;\""
        	psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER RESOURCE GROUP admin_group SET MEMORY_SHARED_QUOTA $rg6_memory_shared_quota;"
		echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"ALTER RESOURCE GROUP admin_group SET CONCURRENCY $rg6_concurrency;\""
                psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER RESOURCE GROUP admin_group SET CONCURRENCY $rg6_concurrency;"
		echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"ALTER RESOURCE GROUP admin_group SET CPU_RATE_LIMIT $rg6_cpu_rate_limit;\""
                psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER RESOURCE GROUP admin_group SET CPU_RATE_LIMIT $rg6_cpu_rate_limit;"

	elif [[ "$VERSION" == "gpdb_7" ]]; then
        	echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"ALTER RESOURCE GROUP admin_group SET MEMORY_LIMIT $rg6_memory_limit;\""
        	psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER RESOURCE GROUP admin_group SET MEMORY_LIMIT $rg6_memory_limit;"
		echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"ALTER RESOURCE GROUP admin_group and default_group SET CPU_HARD_QUOTA_LIMIT $rg7_cpu_hard_quota_limit;\""
		#psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER RESOURCE GROUP admin_group SET CPU_HARD_QUOTA_LIMIT $rg7_cpu_hard_quota_limit;"
		#psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER RESOURCE GROUP default_group SET CPU_HARD_QUOTA_LIMIT $rg7_cpu_hard_quota_limit;"
                echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"ALTER RESOURCE GROUP admin_group SET CONCURRENCY $rg6_concurrency;\""
                psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER RESOURCE GROUP admin_group SET CONCURRENCY $rg6_concurrency;"
                #echo "psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c \"ALTER RESOURCE GROUP admin_group SET CPU_RATE_LIMIT $rg6_cpu_rate_limit;\""
                #psql -d $DBNAME -v ON_ERROR_STOP=1 -q -A -t -c "ALTER RESOURCE GROUP admin_group SET CPU_RATE_LIMIT $rg6_cpu_rate_limit;"

	fi
	set_workfile_limits 
	set_net_core_mem
fi

set_search_path
create_run_sql_from_role
export PGUSER=$RUN_SQL_FROM_ROLE
i=""
id=""
log

end_step $step
