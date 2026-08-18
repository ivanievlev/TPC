#!/bin/bash

# Do not use the name PWD — bash overwrites it on every cd.
SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source "$SCRIPT_DIR/../../functions.sh"
source_bashrc

set -e

SQL_DIR="$SCRIPT_DIR/../05_sql"
QUERIES_DIR="$SCRIPT_DIR/queries"

mkdir -p "$SQL_DIR"

echo "rm -f $SQL_DIR/*.tpch.*.sql"
rm -f "$SQL_DIR"/*.tpch.*.sql

cd "$QUERIES_DIR"

for i in $(ls "$QUERIES_DIR"/*.sql | xargs -n 1 basename); do
	q=$(echo "$i" | awk -F '.' '{print $1}')
	id=$(printf %02d "$q")
	file_id="1""$id"
	filename=$file_id.tpch.$id.sql

	echo "echo \":EXPLAIN_ANALYZE\" > $SQL_DIR/$filename"
	echo ":EXPLAIN_ANALYZE" > "$SQL_DIR/$filename"
	echo "./qgen $q >> $SQL_DIR/$filename"
	./qgen "$q" >> "$SQL_DIR/$filename"
done

cd "$SCRIPT_DIR"
