#!/bin/bash

#SBATCH --nodes=1
#SBATCH --time=05:00:00
#SBATCH --partition=short
#SBATCH --job-name=gzcheck
#SBATCH --array=1-24


# Get all .nc.gz files
NC_FILES=(*.nc.gz)

# Calculate files per task
TOTAL_FILES=${#NC_FILES[@]}
FILES_PER_TASK=$((TOTAL_FILES / 24 + 1))

# Calculate start and end indices for this task
START_IDX=$(((SLURM_ARRAY_TASK_ID - 1) * FILES_PER_TASK))
END_IDX=$((START_IDX + FILES_PER_TASK - 1))

# Test files for this task
for ((i=START_IDX; i<=END_IDX && i<TOTAL_FILES; i++)); do
    NC_FILE=${NC_FILES[i]}
    if [ -f "$NC_FILE" ]; then
        if gzip -tv "$NC_FILE" 2>&1; then
            echo "Task $SLURM_ARRAY_TASK_ID: OK  $NC_FILE"
        else
            echo "Task $SLURM_ARRAY_TASK_ID: BAD $NC_FILE"
        fi
    fi
done
