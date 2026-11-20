#!/bin/bash

#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=12
#SBATCH --time=08:00:00
#SBATCH --partition=short
#SBATCH --job-name=storecheck
#SBATCH --output=logs/storecheck_%j.out

# check_store.sh — check that what is in storage is complete and readable.
# It only reads: nothing is moved, copied or deleted.
#
# Run it from the control directory, as a job (the "gzip" and "cmp" levels read
# every stored archive, which takes hours):
#
#   sbatch aux/check_store.sh [level]
#
# level:
#   size   which archives are in storage, with the same size as the local ones in
#          outputs_raw/gz, and whose gzip trailer matches the size of the original
#          in outputs_raw/raw. Reads a few bytes per file: seconds.
#   gzip   (default) size, plus "gzip -t" on every stored archive and restart.
#   cmp    size, plus a byte-for-byte comparison of every stored archive, once
#          decompressed, with its original in outputs_raw/raw (archives without a
#          local original, and the restarts, get "gzip -t" instead).
#
# Expected folders. Locally, in the control directory (store.sh makes them):
#
#   outputs_raw/gz/<name>.nc.gz       the compressed outputs, kept after the copy
#   outputs_raw/raw/<name>.nc         the uncompressed originals of those archives
#   restarts_raw/restarts.<job>.gz    the year-end restart archive of job <job> (optional)
#   jobscompleted                     one line per finished segment:
#                                     <job> <y> <m> <d> <next y> <next m> <next d>
#
# In storage, under $storage_dir:
#
#   output/<name>.nc.gz               the same archives as outputs_raw/gz, with the same names
#   restart/restarts.<year>.tar.gz    the restart that starts <year>
#
# <name> is the model's file name, for example 20180101.ocean_daily_2018_01.
# A restart is expected for every segment of jobscompleted that ends on Jan 1
# (<next m> = 1 and <next d> = 1); <year> is that segment's <next y>.
#
# storage_dir (the folder that holds output/ and restart/) is taken from the
# environment if it is set, for example sbatch --export=ALL,storage_dir=/path ...
# Otherwise it is read from the file mom.sub.clk.x in the control directory, which
# must contain exactly one line of this form:
#
#   storage_dir="/path/to/storage"     # an optional comment may follow
#
# That line must start in the first column, with no spaces before storage_dir, and
# the path must be inside double quotes. Single quotes, no quotes, or an indented
# line are not found, and the script then stops with "storage_dir is not set".
# If the file has two such lines, both are read and the path is wrong.
#
# Problems are listed in logs/storecheck_<job>.problems, one per line, and the
# result is added to storechecked. The exit code is 1 if there is any problem.

level=${1:-gzip}
case $level in
    size|gzip|cmp) ;;
    *) echo "usage: check_store.sh [size|gzip|cmp]"; exit 1 ;;
esac

ncompress=${ncompress:-12}
ctrldir=${ctrldir:-$PWD}      # a batch job starts in the directory it was submitted from

cd "$ctrldir" || exit 1
mkdir -p logs

if [[ -z ${storage_dir:-} ]]; then
    storage_dir=$(sed -n 's/^storage_dir="\([^"]*\)".*/\1/p' "$ctrldir/mom.sub.clk.x")
fi
: "${storage_dir:?storage_dir is not set, and not found in mom.sub.clk.x}"

dest_out="$storage_dir/output"
dest_rst="$storage_dir/restart"
report="logs/storecheck_${SLURM_JOB_ID:-local}.problems"
: > "$report"
restarts=()

# ─── Functions ────────────────────────────────────────────────────────────────

check_outputs() {
    # every local archive is in storage with the same size, and every original
    # has an archive in storage that ends with its size (gzip stores the size of
    # the input, mod 2^32, in the last 4 bytes)
    local f b orig remote n=0

    echo "CHECK: comparing $dest_out with outputs_raw/gz and outputs_raw/raw ..."
    for f in outputs_raw/gz/*.nc.gz; do
        [ -e "$f" ] || continue
        n=$((n + 1))
        remote="$dest_out/$(basename "$f")"
        if [ ! -f "$remote" ]; then
            echo "MISSING $remote" >> "$report"
        elif [[ $(stat -c %s "$f") != $(stat -c %s "$remote") ]]; then
            echo "SIZE_MISMATCH $remote" >> "$report"
        fi
    done
    echo "CHECK: $n local archives compared."

    for orig in outputs_raw/raw/*.nc; do
        [ -e "$orig" ] || continue
        b=$(basename "$orig")
        remote="$dest_out/$b.gz"
        if [ ! -f "$remote" ]; then
            [ -f "outputs_raw/gz/$b.gz" ] || echo "NO_ARCHIVE $orig" >> "$report"
        elif [[ $(tail -c4 "$remote" | od -An -tu4 | tr -d ' ') != $(( $(stat -c %s "$orig") % 4294967296 )) ]]; then
            echo "TRAILER_MISMATCH $remote" >> "$report"
        fi
    done

    for remote in "$dest_out"/*.nc.gz; do
        [ -e "$remote" ] || continue
        [ -f "outputs_raw/gz/$(basename "$remote")" ] || echo "NOTE: $remote has no local archive (not counted as a problem)"
    done
}

check_restarts() {
    # every segment that ended on Jan 1 has its restart in $dest_rst as
    # restarts.<year>.tar.gz, with the size of the local one if that is still there
    local job y m d ny nm nd remote local_gz

    [ -f jobscompleted ] || { echo "CHECK: no jobscompleted, restarts not checked."; return; }
    echo "CHECK: comparing $dest_rst with the year-end segments of jobscompleted ..."
    while read -r job y m d ny nm nd; do
        (( nm == 1 && nd == 1 )) || continue
        remote="$dest_rst/restarts.$ny.tar.gz"
        local_gz="restarts_raw/restarts.$job.gz"
        if [ ! -f "$remote" ]; then
            echo "MISSING $remote (restart of job $job)" >> "$report"
        elif [ -f "$local_gz" ] && [[ $(stat -c %s "$local_gz") != $(stat -c %s "$remote") ]]; then
            echo "SIZE_MISMATCH $remote" >> "$report"
        else
            restarts+=("$remote")
        fi
    done < <(grep -v '^[[:space:]]*$' jobscompleted)
    echo "CHECK: ${#restarts[@]} restarts found."
}

test_archives() {
    # read every stored archive, $ncompress at a time
    local list=("$@")

    echo "CHECK: reading ${#list[@]} stored archives (level $level) with $ncompress parallel processes..."
    printf '%s\0' "${list[@]}" \
        | xargs -0 -r -P $ncompress -n 1 sh -c '
            report=$1; level=$2; origdir=$3; gz=$4
            orig=$origdir/$(basename "${gz%.gz}")
            if [ "$level" = cmp ] && [ -f "$orig" ]; then
                gzip -dc "$gz" 2>/dev/null | cmp -s - "$orig" || echo "DIFFERS_FROM_ORIGINAL $gz" >> "$report"
            else
                gzip -t "$gz" 2>/dev/null || echo "BAD_GZIP $gz" >> "$report"
            fi' sh "$report" "$level" outputs_raw/raw
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo "CHECK: level $level, storage $storage_dir, from $ctrldir"

check_outputs
check_restarts

narchives=$(ls "$dest_out"/*.nc.gz 2>/dev/null | wc -l)
if [[ $level != size ]]; then
    test_archives "$dest_out"/*.nc.gz "${restarts[@]}"
fi

nproblems=$(grep -vc '^[[:space:]]*$' "$report")
if (( nproblems == 0 )); then
    echo "CHECK: storage OK ($narchives archives, ${#restarts[@]} restarts, level $level)."
else
    echo "CHECK: $nproblems problems, also in $report:"
    cat "$report"
fi

# one line per check, so that "awk '\$5 != 0' storechecked" lists the checks that found problems
echo "$(date +%F_%T) $level $narchives ${#restarts[@]} $nproblems ${SLURM_JOB_ID:-local}" >> $ctrldir/storechecked

(( nproblems == 0 ))
