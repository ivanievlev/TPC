#!/bin/bash
set -e
PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

GPFDIST_PORT=$1
GEN_DATA_PATH=$2
LOG="gpfdist.${GPFDIST_PORT}.log"

if [ -z "$GPFDIST_PORT" ] || [ -z "$GEN_DATA_PATH" ]; then
	echo "Usage: $0 <port> <directory>"
	exit 1
fi

mkdir -p "$GEN_DATA_PATH"

gpfdist -p "$GPFDIST_PORT" -d "$GEN_DATA_PATH" > "$LOG" 2>&1 < "$LOG" &
pid=$!

if [ "$pid" -ne "0" ]; then
	sleep .4
	count=$(ps -ef 2> /dev/null | grep -v grep | awk -F ' ' '{print $2}' | grep $pid | wc -l)
	if [ "$count" -eq "1" ]; then
		echo "Started gpfdist on port $GPFDIST_PORT dir $GEN_DATA_PATH"
	else
		echo "Unable to start gpfdist on port $GPFDIST_PORT dir $GEN_DATA_PATH"
		cat "$LOG" 2>/dev/null || true
		exit 1
	fi
else
	echo "Unable to start background process for gpfdist on port $GPFDIST_PORT"
	exit 1
fi

