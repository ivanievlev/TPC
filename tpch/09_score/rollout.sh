#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $PWD/../../functions.sh
source_bashrc
source $PWD/../../parse_step_args.sh
source $PWD/../../mode.sh
init_tpc_mode
source $PWD/../../external_format.sh
source $PWD/../../score_helpers.sh

if [[ "$GEN_DATA_SCALE" == "" || "$EXPLAIN_ANALYZE" == "" || "$RANDOM_DISTRIBUTION" == "" || "$MULTI_USER_COUNT" == "" || "$SINGLE_USER_ITERATIONS" == "" ]]; then
	echo "Missing required parameters from unified rollout."
	exit 1
fi

step="score"
init_log $step

print_tpc_score
echo ""
print_extended_score_metrics "$TPC_REPORT_SCHEMA" "$TPC_TESTING_SCHEMA"

end_step $step
