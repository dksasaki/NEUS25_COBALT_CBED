#!/bin/bash

# check_store.sh — check that what is in storage is complete and readable.
# It only reads: nothing is moved, copied or deleted.
#
# It is not a Slurm job script. Submit check_store.sub, which sets the resources
# and the settings and calls this script (the "gzip" and "cmp" levels read every
# stored archive, which takes hours):
#
#   sbatch check_store.sub [level]
#
# The "size" level takes seconds and can be run by hand, from the control directory:
#
#   bash aux/check_store.sh size
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
# Variables (all optional except storage_dir, below): ncompress (default 12), the
# number of parallel processes, and check_restarts (default 1); with 0 the restarts
# are not expected in storage and are neither compared nor tested.
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
check_restarts=${check_restarts:-1}     # 0 = do not expect the year-end restarts in storage
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

found() {
    # a problem: written to the report, and printed now so it shows in the log
    echo "$1" >> "$report"
    echo "CHECK: PROBLEM $1"
}

check_outputs() {
    # every local archive is in storage with the same size, and every original
    # has an archive in storage that ends with its size (gzip stores the size of
    # the input, mod 2^32, in the last 4 bytes)
    local f b orig remote n=0 m=0

    echo "CHECK: comparing the size of every archive in outputs_raw/gz with its copy in $dest_out ..."
    for f in outputs_raw/gz/*.nc.gz; do
        [ -e "$f" ] || continue
        n=$((n + 1))
        (( n % 50 == 0 )) && echo "CHECK:   $n archives compared ($(date +%T))"
        remote="$dest_out/$(basename "$f")"
        if [ ! -f "$remote" ]; then
            found "MISSING $remote"
        elif [[ $(stat -c %s "$f") != $(stat -c %s "$remote") ]]; then
            found "SIZE_MISMATCH $remote"
        fi
    done
    echo "CHECK: $n local archives compared."

    echo "CHECK: comparing the size of every original in outputs_raw/raw with the end of its stored archive ..."
    for orig in outputs_raw/raw/*.nc; do
        [ -e "$orig" ] || continue
        m=$((m + 1))
        (( m % 50 == 0 )) && echo "CHECK:   $m originals compared ($(date +%T))"
        b=$(basename "$orig")
        remote="$dest_out/$b.gz"
        if [ ! -f "$remote" ]; then
            [ -f "outputs_raw/gz/$b.gz" ] || found "NO_ARCHIVE $orig"
        elif [[ $(tail -c4 "$remote" | od -An -tu4 | tr -d ' ') != $(( $(stat -c %s "$orig") % 4294967296 )) ]]; then
            found "TRAILER_MISMATCH $remote"
        fi
    done
    echo "CHECK: $m originals compared."

    for remote in "$dest_out"/*.nc.gz; do
        [ -e "$remote" ] || continue
        [ -f "outputs_raw/gz/$(basename "$remote")" ] || echo "NOTE: $remote has no local archive (not counted as a problem)"
    done
}

check_restart_files() {
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
            found "MISSING $remote (restart of job $job)"
        elif [ -f "$local_gz" ] && [[ $(stat -c %s "$local_gz") != $(stat -c %s "$remote") ]]; then
            found "SIZE_MISMATCH $remote"
        else
            restarts+=("$remote")
        fi
    done < <(grep -v '^[[:space:]]*$' jobscompleted)
    echo "CHECK: ${#restarts[@]} restarts found."
}

test_archives() {
    # read every stored archive, $ncompress at a time
    local list=("$@")

    echo "CHECK: reading ${#list[@]} stored archives (level $level) with $ncompress parallel processes ..."
    echo "CHECK:   one line per archive, as each one finishes; they do not come in order"
    # each worker prints "ok <name>" or "PROBLEM <type> <path>"; awk numbers the lines
    printf '%s\0' "${list[@]}" \
        | xargs -0 -r -P $ncompress -n 1 sh -c '
            report=$1; level=$2; origdir=$3; gz=$4
            orig=$origdir/$(basename "${gz%.gz}")
            if [ "$level" = cmp ] && [ -f "$orig" ]; then
                if gzip -dc "$gz" 2>/dev/null | cmp -s - "$orig"; then
                    echo "ok $(basename "$gz") ($(date +%T))"
                else
                    echo "DIFFERS_FROM_ORIGINAL $gz" >> "$report"; echo "PROBLEM DIFFERS_FROM_ORIGINAL $gz"
                fi
            else
                if gzip -t "$gz" 2>/dev/null; then
                    echo "ok $(basename "$gz") ($(date +%T))"
                else
                    echo "BAD_GZIP $gz" >> "$report"; echo "PROBLEM BAD_GZIP $gz"
                fi
            fi' sh "$report" "$level" outputs_raw/raw \
        | awk -v total=${#list[@]} '{ printf "CHECK:   [%d/%d] %s\n", ++n, total, $0; fflush() }'
}

# ─── Main ─────────────────────────────────────────────────────────────────────

start=$SECONDS
echo "CHECK: $(date +%F_%T) started"
echo "CHECK: level $level, storage $storage_dir, from $ctrldir"
echo "CHECK: $ncompress parallel processes, restarts $( ((check_restarts == 1)) && echo checked || echo "not checked (check_restarts=0)" )"

echo "CHECK: step 1 of 3: sizes of the local archives and originals against storage"
check_outputs

if (( check_restarts == 1 )); then
    echo "CHECK: step 2 of 3: year-end restarts"
    check_restart_files
else
    echo "CHECK: step 2 of 3: year-end restarts skipped (check_restarts=0)"
fi

narchives=$(ls "$dest_out"/*.nc.gz 2>/dev/null | wc -l)
if [[ $level != size ]]; then
    echo "CHECK: step 3 of 3: reading the stored archives (level $level)"
    test_archives "$dest_out"/*.nc.gz "${restarts[@]}"
else
    echo "CHECK: step 3 of 3: reading the stored archives skipped (level size)"
fi

nproblems=$(grep -vc '^[[:space:]]*$' "$report")
echo "CHECK: $(date +%F_%T) finished after $(( SECONDS - start )) s"
if (( nproblems == 0 )); then
    echo "CHECK: storage OK ($narchives archives, ${#restarts[@]} restarts, level $level)."
else
    echo "CHECK: $nproblems problems, also in $report:"
    cat "$report"
fi

# one line per check, so that "awk '\$5 != 0' storechecked" lists the checks that found problems
echo "$(date +%F_%T) $level $narchives ${#restarts[@]} $nproblems ${SLURM_JOB_ID:-local}" >> $ctrldir/storechecked

(( nproblems == 0 ))
