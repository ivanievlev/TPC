#!/bin/bash
set -e

count=$(alias | grep -w grep | wc -l)
if [ "$count" -gt "0" ]; then
	unalias grep
fi
count=$(alias | grep -w ls | wc -l)
if [ "$count" -gt "0" ]; then
	unalias ls
fi

#LD_PRELOAD=/lib64/libz.so.1 ps is optional and it caused problems on Astra Linux
#export LD_PRELOAD=/lib64/libz.so.1 ps


LOCAL_PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
OSVERSION=`uname`
ADMIN_USER=`whoami`
ADMIN_HOME=$(eval echo ~$ADMIN_USER)
MASTER_HOST=$(hostname -s)

get_gpfdist_port()
{
	all_ports=$(psql -d postgres -t -A -c "select min(case when role = 'p' then port else 999999 end), min(case when role = 'm' then port else 999999 end) from gp_segment_configuration where content >= 0")
	primary_base=$(echo $all_ports | awk -F '|' '{print $1}' | head -c1)
	mirror_base=$(echo $all_ports | awk -F '|' '{print $2}' | head -c1)

	for i in $(seq 4 9); do
		if [ "$primary_base" -ne "$i" ] && [ "$mirror_base" -ne "$i" ]; then
			GPFDIST_PORT="$i""000"
			break
		fi
	done
}

source_bashrc()
{
	if [ -f ~/.bashrc ]; then
		# don't fail if an error is happening in the admin's profile
		source ~/.bashrc || true
	fi

        if [ -f ~/.bash_profile ]; then
                source ~/.bash_profile || true
        fi
	
        if [ -f ~/.profile ]; then
                # don't fail if an error is happening in the admin's profile
                source ~/.profile || true
        fi

	count=$(grep -v "^#" ~/.bashrc  ~/.*profile | grep "greenplum_path" | wc -l)
	if [ "$count" -eq "0" ]; then
		get_version
		if [[ "$VERSION" == *"gpdb"* ]]; then
			echo "$startup_file does not contain greenplum_path.sh"
			echo "Please update your $startup_file for $ADMIN_USER and try again."
			exit 1
		fi
	fi
}
get_version()
{
	#need to call source_bashrc first
	VERSION=$(psql -d postgres -v ON_ERROR_STOP=1 -t -A -c "SELECT CASE WHEN POSITION ('Greenplum Database 4.3' IN version) > 0 THEN 'gpdb_4_3' WHEN POSITION ('Greenplum Database 5' IN version) > 0 THEN 'gpdb_5' WHEN POSITION ('Greenplum Database 6' IN version) > 0 THEN 'gpdb_6' WHEN POSITION ('Greenplum Database 7' IN version) > 0 THEN 'gpdb_7' ELSE 'postgresql' END FROM version();") 
	if [[ "$VERSION" == *"gpdb"* ]]; then
		if [ "${HEAP_ONLY}" == "true" ]; then
    			HEAP_STORAGE="appendonly=false"
			SMALL_STORAGE="${HEAP_STORAGE}"
    			MEDIUM_STORAGE="${HEAP_STORAGE}"
    			LARGE_STORAGE="${HEAP_STORAGE}"
		else
			if [ "${REFERENCE_TABLE_TYPE}" == "aoco" ]; then
				SMALL_STORAGE="appendonly=true, orientation=column"
			elif [ "${REFERENCE_TABLE_TYPE}" == "aoro" ]; then
				SMALL_STORAGE="appendonly=true, orientation=row"
			elif [ "${REFERENCE_TABLE_TYPE}" == "heap" ]; then
				echo "checked luka"
				SMALL_STORAGE="appendonly=false"
			fi
		MEDIUM_STORAGE="appendonly=true, orientation=column"
		LARGE_STORAGE="appendonly=true, orientation=column, compresstype=zstd, compresslevel=5"
		fi
	else
		SMALL_STORAGE=""
		MEDIUM_STORAGE=""
		LARGE_STORAGE=""
	fi
}
format_duration()
{
	# $1 = elapsed nanoseconds (Linux) or seconds (other)
	local elapsed=$1
	local s m
	if [ "$OSVERSION" == "Linux" ]; then
		s=$((elapsed/1000000000))
		m=$(( (elapsed/1000000) % 1000 ))
	else
		s=$elapsed
		m=0
	fi
	printf "%02d:%02d:%02d.%03d" "$((s/3600%24))" "$((s/60%60))" "$((s%60))" "$m"
}

init_log()
{
	if [ -f $LOCAL_PWD/log/end_$1.log ]; then
		echo "We are skipping step $1"
		exit 0
	else
		echo "end_$1.log is absent so we are starting step $1"
	fi

	logfile=rollout_$1.log

	#A bug when process expects rollout_sql.log occures and I replaced rm for empty 
	> $LOCAL_PWD/log/$logfile
	#rm -f $LOCAL_PWD/log/$logfile

	# wall-clock старта шага (не путать с T из start_log/log по объектам)
	STEP_NAME=$1
	STEP_START_TS=$(date +%F_%T)
	if [ "$OSVERSION" == "Linux" ]; then
		STEP_START_NS="$(date +%s%N)"
	else
		STEP_START_NS="$(date +%s)"
	fi
	echo "Step $STEP_NAME started at $STEP_START_TS"
}

start_log()
{
	if [ "$OSVERSION" == "Linux" ]; then
		T="$(date +%s%N)"
	else
		T="$(date +%s)"
	fi
}

log()
{
	#timestamp
	timing=$(date +%F_%T)
	#duration
	if [ "$OSVERSION" == "Linux" ]; then
		T="$(($(date +%s%N)-T))"
		# whole seconds
		S="$((T/1000000000))"
		# fractional milliseconds (0..999)
		M="$(( (T/1000000) % 1000 ))"
	else
		#must be OSX which doesn't have nano-seconds
		T="$(($(date +%s)-T))"
		S=$T
		M=0
	fi

	#this is done for steps that don't have id values
	# Prefer deriving id from current SQL path $i; only fall back to 1 when $i is unset.
	# (Do not reuse a stale $id from a previous log() call.)
	if [ "${i:-}" = "" ]; then
		id="1"
	else
		id=$(basename "$i" | awk -F '.' '{print $1}')
	fi
	# strip leading zeros so COPY into int works (e.g. 001 -> 1)
	id=$(echo "$id" | sed 's/^0*//')
	if [ "$id" = "" ]; then
		id="1"
	fi

	tuples=$1
	if [ "$tuples" == "" ]; then
		tuples="0"
	fi

	printf "$timing|$id|$schema_name.$table_name|$tuples|%02d:%02d:%02d.%03d\n" "$((S/3600%24))" "$((S/60%60))" "$((S%60))" "${M}" | tee -a  $LOCAL_PWD/log/$logfile 
}

end_step()
{
	local step=$1
	local end_file=$LOCAL_PWD/log/end_$step.log
	local end_ts elapsed duration

	end_ts=$(date +%F_%T)
	if [ -n "${STEP_START_NS:-}" ]; then
		if [ "$OSVERSION" == "Linux" ]; then
			elapsed="$(($(date +%s%N)-STEP_START_NS))"
		else
			elapsed="$(($(date +%s)-STEP_START_NS))"
		fi
		duration=$(format_duration "$elapsed")
	else
		STEP_START_TS=${STEP_START_TS:-unknown}
		duration="unknown"
	fi

	{
		echo "step=$step"
		echo "start=${STEP_START_TS:-unknown}"
		echo "end=$end_ts"
		echo "duration=$duration"
	} > "$end_file"

	echo "Step $step finished: start=${STEP_START_TS:-unknown} end=$end_ts duration=$duration"
}

create_hosts_file()
{
	get_version

	if [[ "$VERSION" == *"gpdb"* ]]; then
		psql -d postgres -v ON_ERROR_STOP=1 -t -A -c "SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role = 'p' AND content >= 0" -o $LOCAL_PWD/segment_hosts.txt
	else
		#must be PostgreSQL
		echo $MASTER_HOST > $LOCAL_PWD/segment_hosts.txt
	fi
}
