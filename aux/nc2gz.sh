#!/bin/bash

#SBATCH --nodes=1
#SBATCH --time=05:00:00
#SBATCH --partition=short
#SBATCH --job-name=moveit
#SBATCH --array=1-21

# Get all .nc files
NC_FILES=($(ls *.nc 2>/dev/null))

# Calculate files per task
TOTAL_FILES=${#NC_FILES[@]}
FILES_PER_TASK=$((TOTAL_FILES / 21 + 1))

# Calculate start and end indices for this task
START_IDX=$(((SLURM_ARRAY_TASK_ID - 1) * FILES_PER_TASK))
END_IDX=$((START_IDX + FILES_PER_TASK - 1))

# Process files for this task
for ((i=START_IDX; i<=END_IDX && i<TOTAL_FILES; i++)); do
    NC_FILE=${NC_FILES[i]}
    if [ -f "$NC_FILE" ] && [[ "$NC_FILE" != *.gz ]]; then
        echo "Task $SLURM_ARRAY_TASK_ID: Compressing $NC_FILE"
        gzip -kf "$NC_FILE"
    fi
done

