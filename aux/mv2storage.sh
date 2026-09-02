#!/bin/bash

#SBATCH --nodes=1
#SBATCH --time=05:00:00
#SBATCH --partition=short
#SBATCH --job-name=moveit
#SBATCH --array=1-24

# Set destination directory
DEST_DIR="/home/d.sasaki/schultz/d.sasaki/experiments/v1.0_simulation/202606_sobolm/20260622_cbed/output"

mkdir -p "$DEST_DIR"

# Get all .nc files
NC_FILES=(*.nc.gz)

# Calculate files per task
TOTAL_FILES=${#NC_FILES[@]}
FILES_PER_TASK=$((TOTAL_FILES / 24 + 1))

# Calculate start and end indices for this task
START_IDX=$(((SLURM_ARRAY_TASK_ID - 1) * FILES_PER_TASK))
END_IDX=$((START_IDX + FILES_PER_TASK - 1))

# Process files for this task
for ((i=START_IDX; i<=END_IDX && i<TOTAL_FILES; i++)); do
    NC_FILE=${NC_FILES[i]}
    if [ -f "$NC_FILE" ]; then
        echo "Task $SLURM_ARRAY_TASK_ID: Moving $NC_FILE to $DEST_DIR"
        rsync -a "$NC_FILE" "$DEST_DIR"
    fi
done
