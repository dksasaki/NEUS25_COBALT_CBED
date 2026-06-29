
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


update input.nml, notice that this is where you can turn on CBED

```
 &generic_COBALT_nml
        co2_calc = 'mocsy'
        debug = .false.
        imbalance_tolerance=1.0e-3
        as_param_cobalt='W92'
        do_external_source=.false.
        do_CBED=.true.
/
```


## Questions you should be able to answer in order to understand the basic MOM6-COBALT structure
what is the objective of the specific namelist files below?

- MOM_input
- MOM_override
- MOM_layout
- COBALT_input
- SIS_input
- SIS_override
- SIS_layout

look at input.nml

- how do you configure the model to start from initial conditions or restart
- where do configure the paths to the specific namelist files?

What are the objectives of?

- data_table
- field_table
- diagnostic_table



----



installing check_mask


```bash
# in your local machine!
sudo apt install nco

# in macos
# brew install nco 


install_dir==/path/to/a/install/dir/of/your/choice

git clone https://github.com/NOAA-GFDL/FRE-NCtools
mkdir install
autoreconf -i
mkdir build && cd build

# prefix will install FRE-NCtools in a directory of your choice (instead of doing it at th root)
../configure --prefix=${install_dir}
make
make install

# in $install_dir there is a bin/check-mask - this is the executable you'll use to create your masks

```



in your  .bash_profile  (in mac) or .bashrc (in linux), let's make check-mask available for the terminal at any location.


```bash
cd $HOME

# edit your .bash_profile/.bashrc
# append the following the ${install_dir}/bin to your $PATH
# $PATH shows the system where to look for binaries
# include the following line in your .bashrc/.bash_profile/.zshrc
export $PATH=$PATH:${install_dir}/bin 
# exit and source the file (use the appropriate one)
# source .bash_profile
source .bashrc
# source .zshrc


# check_mask should be available now. try typing
check_mask --help

# now copy the following files from INPUT
# ocean_mosaic.nc
# ocean_topog.nc
# and include them in a directory of your choice
path_your_dir=/path/to/your/dir

mkdir $path_your_dir
cd $path_your_dir
# copy files to ${path_your_dir}
# to copy from explorer scp your_user_name@xfer.explorer.northeastern.edu:/path/to/files/{ocean_mosaic.nc,ocean_topog.nc, ocean_hgrid.nc} .
check_mask --grid_file ocean_mosaic.nc --ocean_topog ocean_topog.nc  --layout 10,10

# you should see a mask_table.24.10x10 file
# 24 masked cells in a 10x10 grid

# check for more details with check_mask --help
```



