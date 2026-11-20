#!/bin/bash

#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=12
#SBATCH --time=08:00:00
#SBATCH --partition=short
#SBATCH --job-name=store
#SBATCH --output=logs/store_%j.out

# store.sh — compress the outputs of one segment and copy them to storage,
# plus the restart archive when the segment closes a year.
#
# Submitted by mom.sub.clk.x, which exports ctrldir, storage_dir and ncompress.
# <year> is the year the restart starts, i.e. the year the segment ends in.
# To run it by hand (here: job 7, whose restart starts 2019):
#
#   storage_dir=/path/to/storage ncompress=12 \
#       sbatch --export=ALL aux/store.sh 7 2019 1
#
# Arguments: <job> <year> <yearend>
#   <job>      the segment's number, as in the first column of jobscompleted
#   <year>     the year the restart starts, i.e. the year the segment ends in
#   <yearend>  1 if the segment ended on Jan 1 (the restart is then stored too), else 0
#
# Variables, none read from a file: storage_dir must be set, with no default, so an
# sbatch started by hand needs --export=ALL (or ALL,storage_dir=...) as above.
# ncompress (default 12) is the number of parallel processes and should not exceed
# --cpus-per-task. ctrldir (default the submit directory) is the control directory.
#
# Steps, for the outputs:
#   1. compress every outputs_raw/*.nc; a .nc whose .gz already ends with the right
#      size (the last 4 bytes of a gzip file) is skipped
#   2. gzip -t every outputs_raw/*.nc.gz; one that passes moves to outputs_raw/gz and
#      its .nc to outputs_raw/raw, one that fails stays in outputs_raw
#   3. copy to $storage_dir/output every archive of outputs_raw/gz that is not there
#      yet with the same size, then check size and gzip -t of those copies
# and for the restart, only if <yearend> is 1: compress restarts_raw/restarts.<job>
# and copy it to $storage_dir/restart/restarts.<year>.tar.gz, then check it the same way.
# It can be run again: finished work is skipped, and an archive that failed is retried.
# Local files are never deleted.
#
# Expected folders. Locally, in the control directory:
#
#   outputs_raw/<name>.nc           the segment's outputs, moved here by mom.sub.clk.x
#   outputs_raw/gz/<name>.nc.gz     the checked archives (made by step 2)
#   outputs_raw/raw/<name>.nc       their uncompressed originals (made by step 2)
#   restarts_raw/restarts.<job>     the restart tar of the segment, made by mom.sub.clk.x
#   restarts_raw/restarts.<job>.gz  the same, once compressed by this script
#   jobscompleted                   one line per finished segment:
#                                   <job> <y> <m> <d> <next y> <next m> <next d>
#
# In storage, under $storage_dir (the script creates both folders):
#
#   output/<name>.nc.gz             the same archives as outputs_raw/gz, with the same names
#   restart/restarts.<year>.tar.gz  the restart that starts <year>
#
# <name> is the model's file name, for example 20180101.ocean_daily_2018_01.
#
# Result: one line is added to storecompleted for every run, with the columns
#   <job> <year> <yearend> <rc> <slurm job id> <time>
# rc is 0 if everything was copied and checked, else 1; the log is logs/store_<jobid>.out.
# Do not run two store jobs at the same time: they write the same files in storage.
# aux/check_store.sh checks what is in storage afterwards.

job=${1:?usage: store.sh <job> <year> <yearend 0|1>}
year=${2:?usage: store.sh <job> <year> <yearend 0|1>}
yearend=${3:-0}

: "${storage_dir:?storage_dir is not set (mom.sub.clk.x exports it)}"
ncompress=${ncompress:-12}
ctrldir=${ctrldir:-${SLURM_SUBMIT_DIR:-$PWD}}

cd "$ctrldir" || exit 1

# ─── Functions ────────────────────────────────────────────────────────────────

store_outputs() {
    # compress the raw outputs, park the archives in outputs_raw/gz and the
    # uncompressed originals in outputs_raw/raw, then copy the archives to
    # $storage_dir/output. Local copies are always kept.
    local dest="$storage_dir/output"
    local f bad=0
    local archives=()

    mkdir -p "$dest" || { echo "STORE: cannot create $dest, outputs kept local."; return 1; }
    mkdir -p outputs_raw/gz outputs_raw/raw

    # skip a .nc whose .gz already ends with the right original size (the
    # last 4 bytes of a gzip file hold the input size mod 2^32). This reads
    # a few bytes instead of the whole file, and rejects truncated .gz files
    # left by cancelled jobs, which are then rebuilt.
    echo "STORE: compressing outputs with $ncompress parallel processes..."
    find outputs_raw -maxdepth 1 -name '*.nc' -print0 \
        | xargs -0 -r -P $ncompress -n 1 sh -c '
            nc=$1
            if [ -f "$nc.gz" ] \
               && [ "$(tail -c4 "$nc.gz" | od -An -tu4 | tr -d " ")" = "$(( $(stat -c %s "$nc") % 4294967296 ))" ]; then
                echo "STORE: skip $nc (already compressed)"
            else
                gzip -kf "$nc"
            fi' sh

    echo "STORE: verifying archives, moving them to outputs_raw/gz and the originals to outputs_raw/raw..."
    # one archive per worker, $ncompress at a time. Each archive is moved as soon as
    # it passes, so a job that runs out of time keeps its progress, and a rerun only
    # checks what is still in outputs_raw. The original goes to raw first: if the job
    # stops in between, the archive is still in outputs_raw and is checked again.
    find outputs_raw -maxdepth 1 -name '*.nc.gz' -print0 \
        | xargs -0 -r -P $ncompress -n 1 sh -c '
            gz=$1
            nc=${gz%.gz}
            if gzip -t "$gz" 2>/dev/null; then
                [ -f "$nc" ] && mv "$nc" outputs_raw/raw/.
                mv "$gz" outputs_raw/gz/.
            else
                echo "STORE: BAD archive $gz (kept in outputs_raw with its .nc)"
                exit 1
            fi' sh \
        || bad=1

    # copy what is not in storage yet: this job's archives plus anything a
    # previous job failed to transfer completely
    for f in outputs_raw/gz/*.nc.gz; do
        [ -e "$f" ] || continue
        local remote="$dest/$(basename $f)"
        [[ -f $remote ]] && [[ $(stat -c %s "$f") == $(stat -c %s "$remote") ]] || archives+=("$f")
    done

    if (( ${#archives[@]} == 0 )); then
        echo "STORE: nothing to copy."
        return $bad
    fi

    echo "STORE: copying ${#archives[@]} archives to $dest with $ncompress parallel processes..."
    printf '%s\0' "${archives[@]}" \
        | xargs -0 -r -P $ncompress -n 20 sh -c 'rsync -a -- "$@" "$0"' "$dest/" \
        || { echo "STORE: rsync failed."; return 1; }

    echo "STORE: verifying copies in $dest ..."
    local remotes=()
    for f in "${archives[@]}"; do
        local remote="$dest/$(basename $f)"
        if [[ ! -f $remote ]]; then
            echo "STORE: MISSING $remote"; bad=1
        elif [[ $(stat -c %s "$f") != $(stat -c %s "$remote") ]]; then
            echo "STORE: SIZE MISMATCH $remote"; bad=1
        else
            remotes+=("$remote")
        fi
    done

    if (( ${#remotes[@]} > 0 )); then
        printf '%s\0' "${remotes[@]}" \
            | xargs -0 -r -P $ncompress -n 1 \
                sh -c 'gzip -t "$1" 2>/dev/null || { echo "STORE: BAD copy $1"; exit 1; }' sh \
            || bad=1
    fi

    (( bad == 0 )) && echo "STORE: outputs verified in $dest." \
                   || echo "STORE: problems found, local archives kept in outputs_raw/gz."
    return $bad
}

store_restart() {
    # compress and copy the restart archive that starts year $year (the
    # segment ends on Jan 1, so this is the state the year begins from)
    local job=$1 year=$2
    local dest="$storage_dir/restart"
    local tarball="restarts_raw/restarts.$job"
    local remote="$dest/restarts.$year.tar.gz"

    mkdir -p "$dest" || { echo "STORE: cannot create $dest, restart kept local."; return 1; }
    [ -f "$tarball" ] || [ -f "$tarball.gz" ] || { echo "STORE: no restart archive for job $job."; return 1; }

    if [ -f "$tarball" ]; then
        echo "STORE: compressing $tarball ..."
        gzip -f "$tarball" || { echo "STORE: gzip of $tarball failed."; return 1; }
    fi

    echo "STORE: copying year-end restart of $year to $remote ..."
    rsync -a "$tarball.gz" "$remote" || { echo "STORE: rsync failed."; return 1; }

    if [[ $(stat -c %s "$tarball.gz") == $(stat -c %s "$remote") ]] && gzip -t "$remote" 2>/dev/null; then
        echo "STORE: restart verified in $remote."
        return 0
    fi
    echo "STORE: BAD copy $remote (local copy kept in restarts_raw)."
    return 1
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo "STORE: job $job, year $year, yearend $yearend, from $ctrldir"

rc=0
store_outputs || rc=1
if (( yearend == 1 )); then
    store_restart $job $year || rc=1
fi

echo "STORE: done (rc=$rc)"

# one line per segment, so that "awk '\$4 != 0' storecompleted" lists the
# segments whose transfer still needs attention
echo "$job $year $yearend $rc ${SLURM_JOB_ID:-local} $(date +%F_%T)" >> $ctrldir/storecompleted

exit $rc

