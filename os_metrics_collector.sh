#!/bin/bash
# Background OS sampler for TPC score metrics (CPU / RAM / network / disk).
# Usage: os_metrics_collector.sh <outfile> <period_seconds>
# One process per host; SCORE reads log/os_metrics/<hostname>.csv.
# CSV columns (space-separated):
#   ts_unix cpu_idle cpu_total mem_used_bytes net_rx_bytes net_tx_bytes disk_used_bytes
#
# cpu_* are cumulative jiffies from /proc/stat (all CPUs).
# net_* are cumulative bytes over non-loopback interfaces.
# disk_used_bytes is sum of used space on real filesystems (df).

set -u

OUTFILE="${1:?outfile required}"
PERIOD_SEC="${2:?period_seconds required}"

if ! [[ "$PERIOD_SEC" =~ ^[0-9]+$ ]] || [ "$PERIOD_SEC" -lt 1 ]; then
	echo "os_metrics_collector: period_seconds must be an integer >= 1 (got: $PERIOD_SEC)" >&2
	exit 1
fi

mkdir -p "$(dirname "$OUTFILE")"

read_cpu()
{
	# Prints: idle total (jiffies)
	awk '/^cpu / {
		idle=$5+$6
		total=0
		for (i=2; i<=NF; i++) total+=$i
		print idle, total
		exit
	}' /proc/stat
}

read_mem_used()
{
	awk '
		/^MemTotal:/ { tot=$2 }
		/^MemAvailable:/ { avail=$2 }
		/^MemFree:/ { free=$2 }
		/^Buffers:/ { buf=$2 }
		/^Cached:/ { cache=$2 }
		END {
			if (tot == "") { print 0; exit }
			if (avail != "") used = (tot - avail) * 1024
			else used = (tot - free - buf - cache) * 1024
			if (used < 0) used = 0
			print used
		}
	' /proc/meminfo
}

read_net()
{
	# Prints: rx_bytes tx_bytes (sum of non-lo devices)
	awk -F'[: ]+' '
		NR > 2 {
			dev=$2
			gsub(/:/, "", dev)
			if (dev == "" || dev == "lo" || dev ~ /^veth/ || dev ~ /^docker/ || dev ~ /^br-/ || dev ~ /^virbr/) next
			rx+=$3; tx+=$11
		}
		END { print rx+0, tx+0 }
	' /proc/net/dev
}

read_disk_used()
{
	# Sum used bytes; exclude pseudo filesystems.
	df -B1 --local -x tmpfs -x devtmpfs -x overlay -x squashfs -x iso9660 2>/dev/null \
		| awk 'NR>1 { used+=$3 } END { print used+0 }'
}

# Truncate / start fresh for this run
: > "$OUTFILE"

while true; do
	ts=$(date +%s)
	cpu=$(read_cpu)
	mem=$(read_mem_used)
	net=$(read_net)
	disk=$(read_disk_used)
	# shellcheck disable=SC2086
	echo "$ts $cpu $mem $net $disk" >> "$OUTFILE"
	sleep "$PERIOD_SEC"
done
