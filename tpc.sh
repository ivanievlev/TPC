#!/bin/bash
# Convenience entry point for the unified TPC harness (same as tpcds.sh).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tpcds.sh" "$@"
