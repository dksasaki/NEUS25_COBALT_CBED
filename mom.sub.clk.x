#!/bin/bash
#SBATCH -J NWA25_NEUS_bp
#SBATCH --error=NWA25_NEUS.err
#SBATCH --output=NWA25_NEUS.out
#SBATCH --time=1-00:00:00
#SBATCH --partition=long
#SBATCH --mem=32G
#SBATCH --constrain=ib,cascadelake

# ─── Configuration ────────────────────────────────────────────────────────────
njobs=4
dt=3
dt_unit="months"   # "days" or "months"
ctrldir=${PWD}
subscript="mom.sub.clk.x"
subscript_args="--ntasks=$SLURM_NTASKS"
logname="NWA25_NEUS"

source $ctrldir/aux/inject.sh


y0=2005
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

resubmit() {
    cd $ctrldir && sbatch $subscript_args ./$subscript
}

# ─── Main ─────────────────────────────────────────────────────────────────────

source intel_long.env
sleep 10

setup_dirs

thisjob=$(get_job_number)
echo "Starting job #$thisjob"

if [[ $thisjob == 1 ]]; then
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
