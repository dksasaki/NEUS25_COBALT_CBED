
## Experiment 202611_nocbed (branch `exp/202611_nocbed`)

### Objective
1. Run MOM6-COBALT-NEUS25 with CBED off (`do_cbed=.false.` in `input.nml`).
2. Use the outputs as inputs to `cbed_R2py` (`scripts/cbed_wrapper.py`) to build CBED initial conditions.

### Provenance
- Compiled code: `/home/d.sasaki/schultz/d.sasaki/compilation/explorer/20260528_CBEDsinksource`
  - CEFI-regional-MOM6 commit `2496a4f496f8acc2b8c3ed3942b73d585041fd03`
  - `src/ocean_BGC` replaced with https://github.com/dksasaki/ocean_BGC, branch `dev_unify_CBEDv1.0-beta.3_sinksource`, commit `23f708f2f8d1a3738725e6a8c954012809ce6f18`
- Executable: `builds/build/explorer-intel/ocean_ice/repro/MOM6SIS2`, linked as `mom6` (not tracked)
- Working directory: https://github.com/dksasaki/NEUS25_COBALT_CBED, branched from `version_CBEDs2_variable_obc_bgc` at `abb9409`
- Wrapper: https://github.com/dksasaki/cbed_R2py, branch `dev_cbed_v2`, commit `a9ccfa8` (uncommitted local changes)

### Setup
```bash
cd /home/d.sasaki/scratch/mom_experiments2/202611_cbed
git clone https://github.com/dksasaki/NEUS25_COBALT_CBED 202611_nocbed
cd 202611_nocbed
git checkout exp/202611_nocbed
ln -s /home/d.sasaki/schultz/d.sasaki/experiments/inputs_ref/20260622_consolidating_inputs/* INPUT
ln -s /home/d.sasaki/schultz/d.sasaki/compilation/explorer/20260528_CBEDsinksource/builds/build/explorer-intel/ocean_ice/repro/MOM6SIS2 mom6
```

### What the wrapper needs from this run
`cbed_R2py/scripts/model_reader.py` globs these files in `fpath` and averages them over time:

| glob                    | variables                                              | diag_table file          |
|-------------------------|--------------------------------------------------------|--------------------------|
| `*cobalt_btm*.nc`       | `btm_o2`, `btm_no3`, `btm_dic`, bottom N/Si/Fe/P/Ca/lith fluxes | `cobalt_btm%4yr%2mo`     |
| `*cobalt_tracers*.nc`   | `nh4`, `talk` (on `z_l`)                               | `cobalt_tracers%4yr%2mo` |
| `*ocean_daily_*.nc`     | `temp`, `salt` (on `zl`)                               | `ocean_daily%4yr%2mo`    |

Keep the 2D file named `ocean_daily2d_%4yr%2mo`. A name like `ocean_daily_2d` matches `*ocean_daily_*.nc`, and the wrapper then fails because that file has no `temp`.

### Next step (cbed_R2py `config.toml`)
- `fpath`: `<this dir>/outputs_raw` (or `outputs_raw/raw` if `do_store=1`)
- `ftemplate`: a single `*.ocean_daily_YYYY_MM.nc` from this run
