#!/bin/bash

# Script expects the actual capture-guc.sh script to be present in same path as this script
# Usage: ./loop_capture.sh <time_in_minutes> <interval_in_seconds>
# Example: ./loop_capture.sh 10 30

if [ $# -lt 2 ]; then
    echo "Usage: $0 <time_in_minutes> <interval_in_seconds>"
    echo "Example: $0 10 30"
    exit 1
fi

time_minutes=$1
interval_seconds=$2

# Convert minutes to seconds
total_seconds=$((time_minutes * 60))
elapsed=0
iteration=1

echo "Starting loop: ${time_minutes} minutes with ${interval_seconds} second intervals"
echo "Started at $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

while [ $elapsed -lt $total_seconds ]; do
    echo "[Iteration $iteration] $(date '+%Y-%m-%d %H:%M:%S')"
    sudo bash ./capture-guc.sh test_${iteration}.log

    iteration=$((iteration + 1))
    elapsed=$((elapsed + interval_seconds))

    if [ $elapsed -lt $total_seconds ]; then
        sleep $interval_seconds
    fi
done

echo ""
echo "Completed after ${time_minutes} minutes with $((iteration - 1)) total iterations"
echo "Finished at $(date '+%Y-%m-%d %H:%M:%S')"
