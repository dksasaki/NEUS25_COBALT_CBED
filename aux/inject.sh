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

months_to_next_half() {
    local m=$1
    if (( m <= 6 )); then echo $(( 7 - m ))
    else echo $(( 13 - m ))
    fi
}

get_sim_date() {
    local total=$(grep -v '^[[:space:]]*$' $ctrldir/jobscompleted | tail -1 | awk '{print $2}')
    local sy=$(awk '{print $1}' $ctrldir/run_start_date)
    local sm=$(awk '{print $2}' $ctrldir/run_start_date)
    local sd=$(awk '{print $3}' $ctrldir/run_start_date)
    if [[ $dt_unit == "months" ]]; then
        advance_months $sy $sm ${total:-0}
    else
        advance_date $sy $sm $sd ${total:-0}
    fi
}

compute_segment() {
    local y=$1 m=$2 d=$3
    if [[ $dt_unit == "months" ]]; then
        local remaining=$(months_to_next_half $m)
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
        sed -i "s/input_filename = 'r'/input_filename = 'n'/g" $ctrldir/input.nml
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
    sed "s/<YEAR>/$year/g" configs/MOM_override.template > configs/MOM_override
    cd configs && ln -sf MOM_layout.$SLURM_NTASKS MOM_layout && cd ..
}

# ─── Standalone test mode ─────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ctrldir=$(pwd)
    dt=${dt:-6}
    dt_unit=${dt_unit:-"months"}
    y=${1:?usage: inject.sh <year> <month> <day>}
    m=${2:?}
    d=${3:?}
    compute_segment $y $m $d
    echo "Sim date:   $y-$m-$d"
    echo "Segment:    $seg_units $dt_unit ($run_length to inject)"
    echo "--- input.nml before ---"
    grep -E "months|days|current_date|input_filename" $ctrldir/input.nml
    prepare_nml
    update_current_date $y $m $d
    inject_run_length $run_length
    echo "--- input.nml after ---"
    grep -E "months|days|current_date|input_filename" $ctrldir/input.nml
fi
