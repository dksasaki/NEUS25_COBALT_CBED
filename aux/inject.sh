#!/bin/bash
# inject.sh — date arithmetic and namelist injection
# Usage (standalone test): bash inject.sh <year> <month> <day>
# Usage (sourced):          source inject.sh

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

advance_months() {
    local y=$1 m=$2 n=$3
    m=$(( m + n ))
    while (( m > 12 )); do m=$(( m - 12 )); (( y++ )); done
    echo "$y $m 1"
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


months_to_year_end() {
    local m=$1
    echo $(( 13 - m ))
}

#get_sim_date() {
#    local total=$(grep -v '^[[:space:]]*$' $ctrldir/jobscompleted | tail -1 | awk '{print $2}')
#    local sy=$(awk '{print $1}' $ctrldir/run_start_date)
#    local sm=$(awk '{print $2}' $ctrldir/run_start_date)
#    local sd=$(awk '{print $3}' $ctrldir/run_start_date)
#    if [[ $dt_unit == "months" ]]; then
#        advance_months $sy $sm ${total:-0}
#    else
#        advance_date $sy $sm $sd ${total:-0}
#    fi
#}


get_sim_date() {
    if [[ ! -s $ctrldir/jobscompleted ]]; then
        cat $ctrldir/run_start_date
    else
        grep -v '^[[:space:]]*$' $ctrldir/jobscompleted | tail -1 | awk '{print $5, $6, $7}'
    fi
}

advance_sim_date() {
    local y=$1 m=$2 d=$3
    if [[ $dt_unit == "months" ]]; then
        advance_months $y $m $seg_units
    else
        advance_date $y $m $d $seg_units
    fi
}

compute_segment() {
    local y=$1 m=$2 d=$3
    if [[ $dt_unit == "months" ]]; then
        local remaining=$(months_to_year_end $m)
        seg_units=$(( remaining < dt ? remaining : dt ))
        run_length=$seg_units
    else
        local remaining=$(days_to_year_end $y $m $d)
        seg_units=$(( remaining < dt ? remaining : dt ))
        run_length=$seg_units
    fi
}

# ─── Namelist injection ───────────────────────────────────────────────────────

set_run_mode() {
    local job=$1
    if [[ $job == 1 ]]; then
        sed -i "s/input_filename = 'r'/input_filename = 'r'/g" $ctrldir/input.nml
    else
        sed -i "s/input_filename = 'n'/input_filename = 'r'/g" $ctrldir/input.nml
    fi
}

inject_run_length() {
    local n=$1
    if [[ $dt_unit == "months" ]]; then
        sed -i "s/months *= *[0-9]*/months = $n/" $ctrldir/input.nml
        sed -i "s/days *= *[0-9]*/days = 0/"          $ctrldir/input.nml
    else
        sed -i "s/days *= *[0-9]*/days = $n/"     $ctrldir/input.nml
        sed -i "s/months *= *[0-9]*/months = 0/"      $ctrldir/input.nml
    fi
}

reset_run_length() {
    if [[ $dt_unit == "months" ]]; then
        sed -i "s/months *= *[0-9]*/months = <RUN_DAYS>/" $ctrldir/input.nml
        sed -i "s/days *= *[0-9]*/days = 0/"              $ctrldir/input.nml
    else
        sed -i "s/days *= *[0-9]*/days = <RUN_DAYS>/"     $ctrldir/input.nml
        sed -i "s/months *= *[0-9]*/months = 0/"          $ctrldir/input.nml
    fi
}

prepare_nml() {
    cp $ctrldir/templates/input.nml.template $ctrldir/input.nml
}

update_current_date() {
    local y=$1 m=$2 d=$3
    sed -i "s/current_date *= *[0-9, ]*/current_date = $y,$m,$d,0,0,0,/" $ctrldir/input.nml
}

prepare_input_files() {
    local year=$1
    sed "s/<YEAR>/$year/g" data_table.template           > data_table
    sed "s/<YEAR>/$year/g" field_table.template           > field_table
    sed "s/<YEAR>/$year/g" configs/MOM_override.template > configs/MOM_override
    cd configs && ln -sf MOM_layout.$SLURM_NTASKS MOM_layout && cd ..
}

# ─── Standalone test mode ─────────────────────────────────────────────────────
#if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
#    ctrldir=$(pwd)
#    dt=${dt:-2}
#    dt_unit=${dt_unit:-"days"}
#    y=${1:?usage: inject.sh <year> <month> <day>}
#    m=${2:?}
#    d=${3:?}
#    compute_segment $y $m $d
#    echo "Sim date:   $y-$m-$d"
#    echo "Segment:    $seg_units $dt_unit ($run_length to inject)"
#    echo "--- input.nml before ---"
#    grep -E "months|days|current_date|input_filename" $ctrldir/input.nml
#    prepare_nml
#    set_run_mode
#    update_current_date $y $m $d
#    inject_run_length $run_length
#    echo "--- input.nml after ---"
#    grep -E "months|days|current_date|input_filename" $ctrldir/input.nml
#fi

# ─── Standalone test mode ─────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ctrldir=$(pwd)
    y=${1:?usage: inject.sh <year> <month> <day>}
    m=${2:?}
    d=${3:?}

    echo "$y $m $d" > $ctrldir/run_start_date
    rm -f $ctrldir/jobscompleted && touch $ctrldir/jobscompleted

    echo "=== Phase 1: months mode (dt=2) ==="
    dt_unit="months"; dt=2
    for job in 1 2 3; do
        read thisyear thismonth thisday <<< $(get_sim_date)
        compute_segment $thisyear $thismonth $thisday
        read nextyear nextmonth nextday <<< $(advance_sim_date $thisyear $thismonth $thisday)
        echo "Job $job | start: $thisyear-$thismonth-$thisday | seg: $seg_units $dt_unit | end: $nextyear-$nextmonth-$nextday"
        echo "$job $thisyear $thismonth $thisday $nextyear $nextmonth $nextday" >> $ctrldir/jobscompleted
    done

    echo ""
    echo "=== Phase 2: switch to days mode (dt=13) ==="
    dt_unit="days"; dt=13
    for job in 4 5 6; do
        read thisyear thismonth thisday <<< $(get_sim_date)
        compute_segment $thisyear $thismonth $thisday
        read nextyear nextmonth nextday <<< $(advance_sim_date $thisyear $thismonth $thisday)
        echo "Job $job | start: $thisyear-$thismonth-$thisday | seg: $seg_units $dt_unit | end: $nextyear-$nextmonth-$nextday"
        echo "$job $thisyear $thismonth $thisday $nextyear $nextmonth $nextday" >> $ctrldir/jobscompleted
    done

    echo ""
    echo "=== Phase 3: end-of-year cap (months, dt=6) ==="
    dt_unit="months"; dt=6
    echo "6 $thisyear 7 1 $thisyear 7 1" >> $ctrldir/jobscompleted
    for job in 7 8 9; do
        read thisyear thismonth thisday <<< $(get_sim_date)
        compute_segment $thisyear $thismonth $thisday
        read nextyear nextmonth nextday <<< $(advance_sim_date $thisyear $thismonth $thisday)
        echo "Job $job | start: $thisyear-$thismonth-$thisday | seg: $seg_units $dt_unit | end: $nextyear-$nextmonth-$nextday"
        echo "$job $thisyear $thismonth $thisday $nextyear $nextmonth $nextday" >> $ctrldir/jobscompleted
    done

    echo ""
    echo "=== Phase 4: end-of-year cap (days, dt=13) ==="
    dt_unit="days"; dt=13
    echo "9 $thisyear 12 25 $thisyear 12 25" >> $ctrldir/jobscompleted
    for job in 10 11; do
        read thisyear thismonth thisday <<< $(get_sim_date)
        compute_segment $thisyear $thismonth $thisday
        read nextyear nextmonth nextday <<< $(advance_sim_date $thisyear $thismonth $thisday)
        echo "Job $job | start: $thisyear-$thismonth-$thisday | seg: $seg_units $dt_unit | end: $nextyear-$nextmonth-$nextday"
        echo "$job $thisyear $thismonth $thisday $nextyear $nextmonth $nextday" >> $ctrldir/jobscompleted
    done

    echo ""
    echo "=== Phase 5: leap year (days, dt=13, start Feb 20 1996) ==="
    dt_unit="days"; dt=13
    echo "11 1996 2 20 1996 2 20" >> $ctrldir/jobscompleted
    for job in 12 13; do
        read thisyear thismonth thisday <<< $(get_sim_date)
        compute_segment $thisyear $thismonth $thisday
        read nextyear nextmonth nextday <<< $(advance_sim_date $thisyear $thismonth $thisday)
        echo "Job $job | start: $thisyear-$thismonth-$thisday | seg: $seg_units $dt_unit | end: $nextyear-$nextmonth-$nextday"
        echo "$job $thisyear $thismonth $thisday $nextyear $nextmonth $nextday" >> $ctrldir/jobscompleted
    done

    echo ""
    echo "=== Phase 6: month boundary (days, dt=13, start Jan 31 1996) ==="
    dt_unit="days"; dt=13
    echo "13 1996 1 31 1996 1 31" >> $ctrldir/jobscompleted
    for job in 14 15; do
        read thisyear thismonth thisday <<< $(get_sim_date)
        compute_segment $thisyear $thismonth $thisday
        read nextyear nextmonth nextday <<< $(advance_sim_date $thisyear $thismonth $thisday)
        echo "Job $job | start: $thisyear-$thismonth-$thisday | seg: $seg_units $dt_unit | end: $nextyear-$nextmonth-$nextday"
        echo "$job $thisyear $thismonth $thisday $nextyear $nextmonth $nextday" >> $ctrldir/jobscompleted
    done

    echo ""
    echo "=== jobscompleted ==="
    cat $ctrldir/jobscompleted
fi

