#!/bin/bash
#SBATCH -J NWA25_NEUS_bp
#SBATCH --error=NWA25_NEUS.err
#SBATCH --output=NWA25_NEUS.out
#SBATCH --time=1-00:00:00
#SBATCH --partition=long
#SBATCH --mem=32G
#SBATCH --constrain=ib,cascadelake
#SBATCH --exclusive
#SBATCH --exclude=d0086,d0057,d0054

# ─── Configuration ────────────────────────────────────────────────────────────
njobs=12
dt=2
dt_unit="months"   # "days" or "months"
ctrldir=${PWD}
subscript="mom.sub.clk.x"
subscript_args="--ntasks=$SLURM_NTASKS"
logname="NWA25_NEUS"

# ─── Storage ──────────────────────────────────────────────────────────────────
# handled by aux/store.sh, submitted as a separate job after each segment
do_store=0          # 1 = compress outputs and copy them to storage_dir, 0 = off
storage_dir="/path/to/storage"
ncompress=12        # parallel gzip processes

source $ctrldir/aux/inject.sh


y0=2018
m0=1
d0=1
# ─── Functions ────────────────────────────────────────────────────────────────

setup_dirs() {
    for d in RESTART outputs_raw restarts_raw logs; do
        [ ! -d "$d" ] && mkdir "$d"
    done
}

get_job_number() {
    [ ! -f jobscompleted ] && touch jobscompleted
    local last=$(grep -v '^[[:space:]]*$' jobscompleted | tail -1 | awk '{print $1}')
    echo $(( last + 1 ))
}

run_model() {
    mpiexec -np $SLURM_NTASKS --bind-to none --mca pml_base_verbose 10 ./mom6
}

check_run_status() {
    local runok=$(tail -200 ${logname}.out | grep -i "Total runtime")
    local fail1=$(tail -200 ${logname}.out | grep -i "Resource temporarily unavailable")
    local fail2=$(tail -200 ${logname}.err | grep -i "An ORTE daemon has unexpectedly failed after launch and before")
    echo "$fail2" >&2
    if   [[ -n $runok  ]]; then echo "success"
    elif [[ -n $fail1  ]] || [[ -n $fail2 ]]; then echo "mpi_failure"
    else echo "blown_up"
    fi
}

archive_outputs() {
    local job=$1
    mv *.nc ./outputs_raw/.
    tar -cvf restarts.$job RESTART/* && mv restarts.$job ./restarts_raw
    mv RESTART/* RESTART_INPUT/.
    tar -cvf logs.tar.$job \
        MOM_parameter_doc.* SIS_parameter_doc.* \
        ${logname}.err ${logname}.out \
        ocean.stats* logfile.000000.out available_diags.000000 \
        seaice.stats SIS.available_diags SIS_fast.available_diags ocean_stats*
    mv logs.tar.$job ./logs/.
}

submit_store() {
    # hand the compression and the transfer to its own short job, so that
    # neither eats into this allocation's wall time
    local job=$1 year=$2 yearend=$3
    cd $ctrldir && sbatch \
        --export=ALL,ctrldir="$ctrldir",storage_dir="$storage_dir",ncompress="$ncompress" \
        ./aux/store.sh $job $year $yearend
}

resubmit() {
    cd $ctrldir && sbatch $subscript_args ./$subscript
}

# ─── Main ─────────────────────────────────────────────────────────────────────

source intel_long.env
sleep 10

setup_dirs

thisjob=$(get_job_number)
echo "Starting job #$thisjob"

cd INPUT
ln -sf ../RESTART_INPUT/generic_CBED.res.nc
cd ..

if [[ $thisjob == 1 ]]; then
    cd INPUT
    ln -sf cbed_init.nc generic_CBED.res.nc
    cd ..
    sy=$y0
    sm=$m0
    sd=$d0
    echo "$sy $sm $sd" > $ctrldir/run_start_date
fi

read thisyear thismonth thisday <<< $(get_sim_date)
compute_segment $thisyear $thismonth $thisday
echo "Sim date: $thisyear-$thismonth-$thisday | Segment: $seg_units $dt_unit"

prepare_nml
set_run_mode $thisjob
update_current_date $thisyear $thismonth $thisday
inject_run_length $run_length
prepare_input_files $thisyear

run_model

#reset_run_length

status=$(check_run_status)

case $status in
    success)
        archive_outputs $thisjob
        
        read nextyear nextmonth nextday <<< $(advance_sim_date $thisyear $thismonth $thisday)
        echo "$thisjob $thisyear $thismonth $thisday $nextyear $nextmonth $nextday" >> $ctrldir/jobscompleted

	if (( thisjob < njobs )); then
            resubmit
        else
            echo "This is the last job."
        fi

        if (( do_store == 1 )); then
            # segments are capped at the year end, so month=1 day=1 means
            # RESTART holds the restart that starts year $nextyear
            yearend=0
            (( nextmonth == 1 )) && (( nextday == 1 )) && yearend=1
            submit_store $thisjob $nextyear $yearend
        fi
        ;;
    mpi_failure)
        echo "MPI start failed, resubmitting..."
        resubmit
        ;;
    blown_up)
        echo "Run blew up."
        exit 1
        ;;
esac

