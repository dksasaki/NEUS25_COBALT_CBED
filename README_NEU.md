## Compiling MOM6-COBALT-NEUS25+CBED

```bash
your_compilation_dir=/some/path    # where to clone CEFI
mom6_compilation=202606_mom6cobalt_cbed  # modified CEFI name

# cloning CEFI
cd $your_compilation_dir
git clone --recursive https://github.com/NOAA-GFDL/CEFI-regional-MOM6 $mom6_compilation

# checkout a specific commit
cd 202606_mom6cobalt_cbed
git checkout 1542729
git submodule update --init --recursive

# uploading cbed code (commit 98c44d9)
cd src/
mv ocean_BGC ocean_BGC.bk
git clone --recursive https://github.com/dksasaki/ocean_BGC.git
cd ocean_BGC
git checkout dev_unify_CBEDv1.0-beta.3_sinksource
cd ocean_BGC
```


edit generic_CBED.F90, change the line 2327  

```bash
cd "${your_compilation_dir}/${mom6_compilation}"
cd src/MOM6/config_src/external/MARBL
```

edit marbl_interface_public_types.F90, line 49

```diff
- character(len=0) :: varname  !< dummy name
+ character(len=1) :: varname  !< dummy name
```

Compile the model with intel

```bash
cd $your_compilation_dir/$mom6_compilation/builds
./linux-build.bash -m explorer -p intel
```


## Preparing a simulation directory with MOM6+CBED

```bash
your_experiment_dir=/scratch/${USER}/path/to/experiment
your_experiment_name=202606_cbed_test

cd $your_experiment_dir

git clone https://github.com/dksasaki/NEUS25_COBALT_CBED.git $your_experiment_name

# checkout specific branch (the branch commit should be aff3cf6)
cd $your_experiment_name
git checkout version_CBEDs2_variable_obc_bgc

# copy appropriate files in the INPUT directory (I saved reference files in this directory)
ln -s /home/d.sasaki/schultz/d.sasaki/experiments/inputs_ref/20260622_consolidating_inputs/* INPUT

# restart files will be read from a directory RESTART_INPUT

# when starting a run from scratch, DELETE FILES IN RESTART_INPUT
# link (symbolic) the MOM6SIS2 executable you built in the directory (final should be mom6)
ln -s ${your_compilation_dir}/${mom6_compilation}/builds/build/explorer-intel/ocean_ice/repro/MOM6SIS2 mom6
# change the mom.sub.clk.x to use partition sharing and submit a run. Adjust dt. also set up y0 m0 and d0 to match your initial year, month and day (this is not used for restart)
```
