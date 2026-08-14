#!/bin/bash
# Shared helpers for 09_score (TPC-DS and TPC-H). Source after functions.sh / mode.sh / external_format.sh.

bytes_to_gb()
{
	local bytes="${1:-0}"
	bytes=$(echo "$bytes" | tr -d '[:space:]')
	[ -z "$bytes" ] && bytes=0
	echo "scale=3; $bytes / 1024 / 1024 / 1024" | bc
}

# Unix epoch from end_*.log timestamps like 2026-08-14_14:34:34
score_ts_to_unix()
{
	local ts="$1"
	ts=${ts//_/ }
	date -d "$ts" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null || echo ""
}

score_read_end_log_range()
{
	# $1 = path to end_*.log → prints "start_unix end_unix" or empty
	local f="$1"
	local start_s end_s start_u end_u
	[ -f "$f" ] || return 0
	start_s=$(awk -F= '/^start=/{print $2; exit}' "$f")
	end_s=$(awk -F= '/^end=/{print $2; exit}' "$f")
	[ -n "$start_s" ] && [ -n "$end_s" ] || return 0
	start_u=$(score_ts_to_unix "$start_s")
	end_u=$(score_ts_to_unix "$end_s")
	[ -n "$start_u" ] && [ -n "$end_u" ] || return 0
	echo "$start_u $end_u"
}

# Min start / max end across end_testing_*.log (multi-user window)
score_multi_user_time_range()
{
	local start_u="" end_u="" s e pair
	local log_dir="${LOCAL_PWD:-$PWD/../..}/log/end_testing_log"
	[ -d "$log_dir" ] || log_dir="$PWD/../../log/end_testing_log"
	for f in "$log_dir"/end_testing_*.log; do
		[ -f "$f" ] || continue
		pair=$(score_read_end_log_range "$f")
		[ -n "$pair" ] || continue
		s=$(echo "$pair" | awk '{print $1}')
		e=$(echo "$pair" | awk '{print $2}')
		if [ -z "$start_u" ] || [ "$s" -lt "$start_u" ]; then start_u=$s; fi
		if [ -z "$end_u" ] || [ "$e" -gt "$end_u" ]; then end_u=$e; fi
	done
	[ -n "$start_u" ] && [ -n "$end_u" ] && echo "$start_u $end_u"
}

# Bytes of generated flat files (.dat / .tbl*) under PGDATA (and remote hosts if listed).
score_dat_bytes()
{
	local total=0 chunk hosts_file host

	_sum_under() {
		local root="$1"
		[ -n "$root" ] && [ -d "$root" ] || { echo 0; return; }
		find "$root" -type f \( -name '*.dat' -o -name '*.dat.gz' -o -name '*.tbl' -o -name '*.tbl.*' \) -printf '%s\n' 2>/dev/null \
			| awk '{s+=$1} END{print s+0}'
	}

	if [ -n "${PGDATA:-}" ] && [ -d "$PGDATA" ]; then
		total=$(_sum_under "$PGDATA")
	fi

	hosts_file="${LOCAL_PWD:-}/segment_hosts.txt"
	[ -f "$hosts_file" ] || hosts_file="$PWD/../../segment_hosts.txt"
	if [ -f "$hosts_file" ]; then
		while read -r host; do
			[ -z "$host" ] && continue
			[ "$host" = "$(hostname -s)" ] && continue
			chunk=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$host" \
				'if [ -n "${PGDATA:-}" ] && [ -d "$PGDATA" ]; then find "$PGDATA" -type f \( -name "*.dat" -o -name "*.dat.gz" -o -name "*.tbl" -o -name "*.tbl.*" \) -printf "%s\n" 2>/dev/null | awk "{s+=\$1} END{print s+0}"; else echo 0; fi' \
				2>/dev/null || echo 0)
			chunk=$(echo "$chunk" | tr -d '[:space:]')
			[ -z "$chunk" ] && chunk=0
			total=$(echo "$total + $chunk" | bc)
		done < "$hosts_file"
	fi
	echo "${total:-0}"
}

# Bytes occupied by benchmark data in DB (heap) or external format tree.
score_storage_bytes()
{
	local bytes=0
	case "${USE_EXTERNAL_FORMAT:-false}" in
		parquet|csv|json)
			if type external_data_root >/dev/null 2>&1; then
				local root
				root=$(external_data_root)
				if [ -d "$root" ]; then
					bytes=$(du -sb "$root" 2>/dev/null | awk '{print $1}')
				fi
			fi
			;;
		*)
			bytes=$(psql -d "$DBNAME" -v ON_ERROR_STOP=1 -q -t -A -c "SELECT pg_database_size(current_database());" 2>/dev/null | tr -d '[:space:]')
			;;
	esac
	bytes=$(echo "${bytes:-0}" | tr -d '[:space:]')
	[ -z "$bytes" ] && bytes=0
	echo "$bytes"
}

# Success % from reports/testing .sql table. Successful = 'succesfull' (legacy spelling) or empty.
# Failures = ERROR:* or cancelled due to timeout.
score_query_success_pct()
{
	local schema="$1"
	local table="${2:-sql}"
	psql -d "$DBNAME" -v ON_ERROR_STOP=0 -q -t -A -c "
SELECT CASE WHEN count(*) = 0 THEN 0
       ELSE round(100.0 * count(*) FILTER (
              WHERE coalesce(query_status, '') = ''
                 OR query_status = 'succesfull'
                 OR query_status = 'successful'
            ) / count(*), 2)
       END
FROM ${schema}.${table};
" 2>/dev/null | tr -d '[:space:]'
}

check_prometheus_available()
{
	local url="${PROMETHEUS_URL:-}"
	url=${url%/}
	if [ -z "$url" ]; then
		echo "ERROR: COLLECT_PROMETHEUS_DATA=true but PROMETHEUS_URL is empty."
		echo "Set PROMETHEUS_URL to the Prometheus HTTP base (e.g. http://prom.example:9090)."
		return 1
	fi
	if ! command -v curl >/dev/null 2>&1; then
		echo "ERROR: COLLECT_PROMETHEUS_DATA=true but curl is not installed."
		return 1
	fi
	local code
	code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$url/-/ready" 2>/dev/null || true)
	[ -z "$code" ] && code="000"
	if [ "$code" != "200" ]; then
		code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$url/api/v1/status/buildinfo" 2>/dev/null || true)
		[ -z "$code" ] && code="000"
	fi
	if [ "$code" != "200" ]; then
		echo "ERROR: COLLECT_PROMETHEUS_DATA=true but Prometheus is not reachable at PROMETHEUS_URL=$url (HTTP $code)."
		echo "Fix PROMETHEUS_URL or set COLLECT_PROMETHEUS_DATA=false."
		return 1
	fi
	echo "Prometheus OK at PROMETHEUS_URL=$url"
	return 0
}

# avg_over_time of an instant-vector expression over [start,end] via Prometheus API.
# Prints numeric value or "n/a"
prometheus_avg_over_window()
{
	local expr="$1"
	local start_u="$2"
	local end_u="$3"
	local url="${PROMETHEUS_URL:-}"
	url=${url%/}
	if [ -z "$url" ]; then
		echo "n/a"
		return 0
	fi
	local window=$((end_u - start_u))
	[ "$window" -lt 1 ] && window=1
	# Evaluate at end time with lookbehind window
	local query="avg_over_time(($expr)[${window}s:])"
	local json val
	json=$(curl -sgG --connect-timeout 5 --max-time 30 "$url/api/v1/query" \
		--data-urlencode "query=$query" \
		--data-urlencode "time=$end_u" 2>/dev/null || true)
	val=$(printf '%s' "$json" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    r=d.get("data",{}).get("result",[])
    if not r:
        print("n/a"); sys.exit(0)
    v=r[0]["value"][1]
    print(v)
except Exception:
    print("n/a")
' 2>/dev/null || echo "n/a")
	echo "$val"
}

score_prometheus_for_window()
{
	local label="$1"
	local start_u="$2"
	local end_u="$3"
	local cpu ram net disk

	if [ -z "$start_u" ] || [ -z "$end_u" ]; then
		printf "%-36s %14s\n" "$label CPU avg %" "n/a"
		printf "%-36s %14s\n" "$label RAM used avg GB" "n/a"
		printf "%-36s %14s\n" "$label Network avg MB/s" "n/a"
		printf "%-36s %14s\n" "$label Disk used avg GB" "n/a"
		return 0
	fi

	cpu=$(prometheus_avg_over_window '100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[1m])))' "$start_u" "$end_u")
	ram=$(prometheus_avg_over_window '(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1024 / 1024 / 1024' "$start_u" "$end_u")
	# Fallback if MemAvailable missing
	if [ "$ram" = "n/a" ]; then
		ram=$(prometheus_avg_over_window '(node_memory_MemTotal_bytes - node_memory_MemFree_bytes - node_memory_Buffers_bytes - node_memory_Cached_bytes) / 1024 / 1024 / 1024' "$start_u" "$end_u")
	fi
	net=$(prometheus_avg_over_window 'sum(rate(node_network_receive_bytes_total{device!~"lo|veth.*|docker.*"}[1m]) + rate(node_network_transmit_bytes_total{device!~"lo|veth.*|docker.*"}[1m])) / 1024 / 1024' "$start_u" "$end_u")
	disk=$(prometheus_avg_over_window 'sum(node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs"} - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"}) / 1024 / 1024 / 1024' "$start_u" "$end_u")

	_fmt() {
		local v="$1"
		if [ "$v" = "n/a" ] || [ -z "$v" ]; then
			echo "n/a"
		else
			printf '%.3f' "$v" 2>/dev/null || echo "$v"
		fi
	}

	printf "%-36s %14s\n" "$label CPU avg %" "$(_fmt "$cpu")"
	printf "%-36s %14s\n" "$label RAM used avg GB" "$(_fmt "$ram")"
	printf "%-36s %14s\n" "$label Network avg MB/s" "$(_fmt "$net")"
	printf "%-36s %14s\n" "$label Disk used avg GB" "$(_fmt "$disk")"
}

print_extended_score_metrics()
{
	local report_schema="$1"
	local testing_schema="$2"
	local dat_b stor_b dat_gb stor_gb pct05 pct07
	local pair05 pair07 s05 e05 s07 e07
	local stor_label

	dat_b=$(score_dat_bytes)
	stor_b=$(score_storage_bytes)
	dat_gb=$(bytes_to_gb "$dat_b")
	stor_gb=$(bytes_to_gb "$stor_b")
	pct05=$(score_query_success_pct "$report_schema" sql)
	pct07=$(score_query_success_pct "$testing_schema" sql)
	[ -z "$pct05" ] && pct05=0
	[ -z "$pct07" ] && pct07=0

	case "${USE_EXTERNAL_FORMAT:-false}" in
		parquet|csv|json) stor_label="Storage (${USE_EXTERNAL_FORMAT}) GB" ;;
		*) stor_label="Database size GB" ;;
	esac

	printf "%-36s %14.3f\n" "DAT/TBL flat files GB" "$dat_gb"
	printf "%-36s %14.3f\n" "$stor_label" "$stor_gb"
	printf "%-36s %14s\n" "05_sql success %" "$pct05"
	printf "%-36s %14s\n" "07_multi_user success %" "$pct07"

	if [ "${COLLECT_PROMETHEUS_DATA:-true}" = "true" ]; then
		echo ""
		printf "%-36s %14s\n" "---- Prometheus (05_sql) ----" ""
		pair05=$(score_read_end_log_range "${LOCAL_PWD:-$PWD/../..}/log/end_sql.log")
		[ -z "$pair05" ] && pair05=$(score_read_end_log_range "$PWD/../../log/end_sql.log")
		s05=$(echo "$pair05" | awk '{print $1}')
		e05=$(echo "$pair05" | awk '{print $2}')
		score_prometheus_for_window "05" "$s05" "$e05"

		echo ""
		printf "%-36s %14s\n" "---- Prometheus (07_multi) ----" ""
		pair07=$(score_multi_user_time_range)
		s07=$(echo "$pair07" | awk '{print $1}')
		e07=$(echo "$pair07" | awk '{print $2}')
		score_prometheus_for_window "07" "$s07" "$e07"
	fi
}
