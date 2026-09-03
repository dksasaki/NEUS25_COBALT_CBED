#!/bin/bash

#SBATCH --nodes=1
#SBATCH --time=05:00:00
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

    echo "STORE: compressing outputs with $ncompress parallel processes..."
    find outputs_raw -maxdepth 1 -name '*.nc' -print0 \
        | xargs -0 -r -P $ncompress -n 1 gzip -kf

    echo "STORE: verifying archives, moving them to outputs_raw/gz and the originals to outputs_raw/raw..."
    for f in outputs_raw/*.nc.gz; do
        [ -e "$f" ] || continue
        if gzip -t "$f" 2>/dev/null; then
            mv "$f" outputs_raw/gz/.
            [ -f "${f%.gz}" ] && mv "${f%.gz}" outputs_raw/raw/.
        else
            echo "STORE: BAD archive $f (kept in outputs_raw with its .nc)"
            bad=1
        fi
    done

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

