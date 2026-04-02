#!/bin/bash
#SBATCH -J NWA25_NEUS_bp
#SBATCH --error=NWA25_NEUS.err
#SBATCH --output=NWA25_NEUS.out
#SBATCH --time=01:00:00
#SBATCH --partition=sharing
#SBATCH --mem=32G
#SBATCH --constrain=ib,zen2
#SBATCH --exclude=d3205


# ─── Configuration ────────────────────────────────────────────────────────────
njobs=30
ctrldir=$(pwd)
subscript="mom.sub.zen2.x"
subscript_args="--ntasks=$SLURM_NTASKS"
logname="NWA25_NEUS"
dt=2
# ─── Date arithmetic ──────────────────────────────────────────────────────────

is_leap() {
    local y=$1
    (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )) && echo 1 || echo 0
}

days_in_month() {
    local m=$1 y=$2
    local days=(0 31 28 31 30 31 30 31 31 30 31 30 31)
    [[ $m == 2 ]] && [[ $(is_leap $y) == 1 ]] && echo 29 || echo ${days[$m]}
}

advance_date() {
    local y=$1 m=$2 d=$3 n=$4
    local dim remaining
    while (( n > 0 )); do
        dim=$(days_in_month $m $y)
        remaining=$(( dim - d ))
        if (( n <= remaining )); then
            d=$(( d + n ))
            n=0
        else
            n=$(( n - remaining - 1 ))
            d=1
            (( m++ ))
            if (( m > 12 )); then m=1; (( y++ )); fi
        fi
    done
    echo "$y $m $d"
}

days_to_year_end() {
    local y=$1 m=$2 d=$3
    local doy=0
    local days=(0 31 28 31 30 31 30 31 31 30 31 30 31)
    [[ $(is_leap $y) == 1 ]] && days[2]=29
    for (( i=1; i<m; i++ )); do doy=$(( doy + days[i] )); done
    doy=$(( doy + d ))
    local total=$(( $(is_leap $y) == 1 ? 366 : 365 ))
    echo $(( total - doy + 1 ))
}

get_sim_date() {
    local total_days=$(grep -v '^[[:space:]]*$' $ctrldir/jobscompleted | tail -1 | awk '{print $2}')
    local sy=$(awk '{print $1}' $ctrldir/run_start_date)
    local sm=$(awk '{print $2}' $ctrldir/run_start_date)
    local sd=$(awk '{print $3}' $ctrldir/run_start_date)
    advance_date $sy $sm $sd ${total_days:-0}
}

compute_run_length() {
    local remaining=$(days_to_year_end $1 $2 $3)
    (( remaining < $dt )) && echo $remaining || echo $dt
}

# ─── Functions ────────────────────────────────────────────────────────────────

setup_dirs() {
    for d in RESTART outputs_raw restarts_raw logs; do
        [ ! -d "$d" ] && mkdir "$d"
    done
}

get_job_number() {
    [ ! -f jobscompleted ] && touch jobscompleted
    #local last=$(tail -1 jobscompleted | awk '{print $1}')
    local last=$(grep -v '^[[:space:]]*$' jobscompleted | tail -1 | awk '{print $1}')
    echo $(( last + 1 ))
}

set_run_mode() {
    local job=$1
    if [[ $job == 1 ]]; then
        sed -i "s/input_filename = 'r'/input_filename = 'n'/g" $ctrldir/input.nml
    else
        sed -i "s/input_filename = 'n'/input_filename = 'r'/g" $ctrldir/input.nml
    fi
}

inject_run_length() {
    local n=$1
    sed -i "s/days *= *<RUN_DAYS>/days = $n/" $ctrldir/input.nml
}

reset_run_length() {
    sed -i "s/days *= *[0-9]*/days = <RUN_DAYS>/" $ctrldir/input.nml
}

update_current_date() {
    local y=$1 m=$2 d=$3
    sed -i "s/current_date *= *[0-9, ]*/current_date = $y,$m,$d,0,0,0,/" $ctrldir/input.nml
}

prepare_input_files() {
    local year=$1
    sed "s/<YEAR>/$year/g" data_table.template           > data_table
    sed "s/<YEAR>/$year/g" configs/MOM_override.template > configs/MOM_override
    cd configs && ln -sf MOM_layout.$SLURM_NTASKS MOM_layout && cd ..
}

run_model() {
    mpiexec -np $SLURM_NTASKS --mca pml_base_verbose 10 ./mom6
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
    mv RESTART/* INPUT/.
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

source amd.env
sleep 10

setup_dirs

thisjob=$(get_job_number)
echo "Starting job #$thisjob"

# store original start date once on job 1
if [[ $thisjob == 1 ]]; then
    line=$(grep "current_date" $ctrldir/input.nml | sed "s/,/ /g")
    sy=$(echo $line | awk '{print $3}')
    sm=$(echo $line | awk '{print $4}')
    sd=$(echo $line | awk '{print $5}')
    echo "$sy $sm $sd" > $ctrldir/run_start_date
fi

read thisyear thismonth thisday <<< $(get_sim_date)
run_length=$(compute_run_length $thisyear $thismonth $thisday)
echo "Sim date: $thisyear-$thismonth-$thisday | Run length: $run_length days"

set_run_mode $thisjob
update_current_date $thisyear $thismonth $thisday
inject_run_length $run_length
prepare_input_files $thisyear

run_model

reset_run_length

status=$(check_run_status)

case $status in
    success)
        archive_outputs $thisjob
        prev_days=$(tail -1 $ctrldir/jobscompleted | awk '{print $2}')
        total_days=$(( ${prev_days:-0} + run_length ))
        echo "$thisjob $total_days" >> $ctrldir/jobscompleted
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
