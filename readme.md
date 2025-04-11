# RStudio on Linux server

## How to make the environment

1. Make an environment with apptainer, it is the only program needed.
2. Create a directory `$CONDA_PREFIX/rstudio-images`
3. Download correct images: `apptainer pull docker://bioconductor/bioconductor_docker:devel`
4. Copy the `run.sh` script to `$CONDA_PREFIX/bin` as `rstudio-web`, make sure it is executable.
5. Copy the `message.sh` script to `$cONDA_PREFIX/etc/conda/activate.d/`, make the directory if not exist.

Note: Make sure your image have development tools for building some R packages.

## What will happen on user side

### RStudio Execution

- The RStudio server runs within an Apptainer container
- When launched, you'll receive:
  - A randomly generated port number
  - A randomly generated password for your session
  - SSH tunneling instructions for remote access
  - Direct URL for local access
- You can specify CPU cores and custom port numbers with options like `--cpus` and `--port`

### Temporary Files in Home Directory

- Two temporary files will be created in your home directory:
  - `custom_rsession.conf`: Configuration for your R session
  - A symlink to `/vol/local` at `~/vol-local-entry-RSTUDIO`
- These files are automatically removed when your session ends

### R Package Installation

- R packages are installed to `/vol/local/$USER/Rstudio/$R_VERSION`
- This location persists between sessions
- The R version is automatically detected from the container
- Using this location keeps your packages organized by R version

### R Session Workspace

- Your R workspace defaults to `/vol/local/$USER/RStudio/workspace`
- This prevents clutter in your home directory
- The `.RData` and history files are stored in this location
- This directory is created automatically if it doesn't exist

### CPU Core Allocation

- By default, your session uses all available CPU cores
- You can limit CPU usage with `--cpus N` to use N cores
- You can specify exact cores with `--cpus 0,2,4` syntax
- The system manages core allocations to prevent conflicts between users
- Allocated cores are automatically released when your session ends
