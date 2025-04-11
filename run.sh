#!/bin/bash

# This script runs RStudio Server in an Apptainer container.
# It allows you to specify the number of CPU cores and the port number.
# It also handles cleanup of temporary files and core allocations.

# Define default container image
# Get the directory where this script is located
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SIF="${SCRIPT_DIR}/../rstudio-images/bioconductor_docker_devel.sif"
# Default to not use `taskset` (use all cores)
NCPU=0
# Default to use an auto-generated port
PORT=""

# Define temporary files and directories
# These will be removed upon exit
VOL_LOCAL_ENTRY="vol-local-entry-RSTUDIO"
RSESSION_CONF=$HOME"/custom_rsession.conf"
TMPDIR=/tmp/$USER"-rserver-"$$

# Function to display help information
print_help() {
    echo "Usage: $(basename $0) [OPTIONS]"
    echo
    echo "Run RStudio Server in an Apptainer container."
    echo
    echo "Options:"
    echo "  --help          Display this help message and exit"
    echo "  --cpus NUM      Specify the number of CPU cores to use"
    echo "                  Default: 0 (use all available cores)"
    echo "  --cpus LIST     Specify exact CPU cores to use as comma-separated list (e.g., 0,1,4)"
    echo "  --sif FILE      Specify the Apptainer/Singularity image file (.sif) to use"
    echo "                  Default: $SIF"
    echo "                  The target image must have RStudio Server installed"
    echo "  --port PORT     Specify a port number for RStudio Server (must be between 49152 and 65535)"
    echo "                  WARNING: Set this up manually may cause conflicts with other users!"
    echo "                  Default: randomly selected available port"
    echo
    echo "Examples:"
    echo "  $(basename $0)                                  # Run with default settings (all cores, random port)"
    echo "  $(basename $0) --cpus 2                         # Run with 2 CPU cores"
    echo "  $(basename $0) --cpus 0,2,4                     # Run on specific CPU cores 0, 2, and 4"
    echo "  $(basename $0) --sif rstudio_latest.sif         # Run using a specific container image file"
    echo "  $(basename $0) --port 50040                     # Run on port 50000 with all cores"
    echo "  $(basename $0) --port 50000 --cpus 2            # Run on port 50000 with 2 CPU cores"
    echo
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    --help | -h)
        print_help
        ;;
    --sif)
        SIF="$2"
        # Validate SIF file exists
        if [ ! -f "$SIF" ]; then
            echo "Error: SIF file '$SIF' not found"
            exit 1
        fi
        shift 2
        ;;
    --port)
        PORT="$2"
        # Validate port is in range
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 49152 ] || [ "$PORT" -gt 65535 ]; then
            echo "Error: Port must be between 49152 and 65535"
            exit 1
        fi
        shift 2
        ;;
    --cpus)
        if [[ "$2" == *","* ]]; then
            # Explicit CPU list provided (like 0,1,33)
            CORES="$2"
            NCPU=-1 # Special flag to indicate explicit cores
        else
            # Number of CPUs provided
            NCPU="$2"
            if ! [[ "$NCPU" =~ ^[0-9]+$ ]]; then
                echo "Error: --cpus must be a number or comma-separated list of CPU numbers"
                exit 1
            fi
        fi
        shift 2
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use '--help' for usage information"
        exit 1
        ;;
    esac
done

# Generate a random available port if not specified
if [ -z "$PORT" ]; then
    PORT=$(comm -23 <(seq 49152 65535 | sort) <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 1)
fi

# Make a link point to the local volume
if [ ! -L $HOME/$VOL_LOCAL_ENTRY ]; then
    ln -s /home/rstudio/$VOL_LOCAL_ENTRY $HOME/$VOL_LOCAL_ENTRY
fi

# Generate a random password
pw="$(openssl rand -base64 12)"

# Output information for the user
echo "Starting RStudio Server on port $PORT"
echo
echo "How to use"
echo "    For SSH user:"
echo "        Open a new terminal on your local machine and run"
echo "        ssh -N -L 8787:localhost:${PORT} ${USER}@<server-address>"
echo "        Then open http://localhost:8787 in your browser"
echo "        (change local port 8787 at your convinience)"
echo
echo "    For local user:"
echo "        Open http://localhost:${PORT} in your browser"
echo
echo "    Username $USER"
echo "    Password $pw"
echo
echo "    /vol/local/ is mapped to /home/rstudio/$VOL_LOCAL_ENTRY"
echo
echo "Temporary files created in home directory (will be removed upon exit):"
echo $RSESSION_CONF
echo $HOME/$VOL_LOCAL_ENTRY

touch $RSESSION_CONF
# Extract R version from the container
echo
echo "Extracting R version from the container..."
R_VERSION=$(apptainer exec $SIF Rscript --version | grep -oP '(?<=version )[0-9]+\.[0-9]+\.[0-9]+')
echo "Detected R version: $R_VERSION"

# Create a workspace directory in the mounted volume
# This prevent RStudio from creating workspace in the home directory
WORKSPACE_DIR="/home/rstudio/$VOL_LOCAL_ENTRY/$USER/RStudio/workspace"
cat > $RSESSION_CONF << EOF
# Library path
r-libs-user=/home/rstudio/$VOL_LOCAL_ENTRY/$USER/Rstudio/$R_VERSION

# Set workspace location (this is where .RData will be saved)
session-default-working-dir=$WORKSPACE_DIR
session-default-new-project-dir=$WORKSPACE_DIR
EOF
# Make sure the workspace directory exists in the mounted volume
mkdir -p "/vol/local/$USER/RStudio/workspace"

# Make all temporary directories
mkdir -p $TMPDIR/var/lib/rstudio-server
mkdir -p $TMPDIR/var/run/rstudio-server
mkdir -p $TMPDIR/var/log/rstudio-server
mkdir -p $TMPDIR/tmp

echo "/vol/local/"$USER"/Rstudio/"$R_VERSION" will be used to store R libraries."

# Build the command string
cmd="PASSWORD=\"$pw\""

if [ $NCPU -gt 0 ]; then
    TOTAL_CORES=$(nproc)

    CORE_FILE="/var/tmp/rstudio_core_allocation.lock"
    CORE_PID_MAP="/var/tmp/rstudio_core_pid_map.txt"
    CORE_FLOCK="/var/tmp/rstudio_core_allocation.lock.flock"
    CORES=""
    # Create the file if it doesn't exist
    touch $CORE_FILE $CORE_FLOCK $CORE_PID_MAP 2>/dev/null
    chmod 666 $CORE_FILE $CORE_FLOCK $CORE_PID_MAP 2>/dev/null

    # Use flock to prevent race conditions and capture CORES value
    CORES=$(
        exec 200>$CORE_FLOCK
        flock -x 200

        # Read current allocations
        ALLOCATED_CORES=$(cat $CORE_FILE 2>/dev/null || echo "")
        echo "Cores already in use: $ALLOCATED_CORES" >&2

        # Find all available cores first
        all_available=""
        for ((i = 0; i < TOTAL_CORES; i++)); do
            if ! echo ",$ALLOCATED_CORES," | grep -q ",$i,"; then
                [ -n "$all_available" ] && all_available+=","
                all_available+="$i"
            fi
        done
        echo "Available cores: $all_available" >&2

        # Select cores to use from available cores
        local_cores=""
        for ((i = 0; i < TOTAL_CORES && $(echo "$local_cores" | tr ',' ' ' | wc -w) < NCPU; i++)); do
            if ! echo ",$ALLOCATED_CORES," | grep -q ",$i,"; then
                [ -n "$local_cores" ] && local_cores+=","
                local_cores+="$i"
            fi
        done

        # Update the allocation file
        echo "$ALLOCATED_CORES,$local_cores" | tr ',' '\n' | sort -nu | tr '\n' ',' | sed 's/^,//;s/,$//' >$CORE_FILE

        # Register cleanup on exit
        echo "$$,$local_cores" >>$CORE_PID_MAP

        # Close the file descriptor after the subshell completes
        exec 200>&-
        # Output the cores so they can be captured by the main script
        echo "$local_cores"
    )

    echo "Using $NCPU CPU cores: $CORES"
    cmd+=" taskset -c $CORES"

    # Add a trap to release cores when this script exits
    CLEANUP_DONE=0
    cleanup_core_lock() {
        # Only run once
        if [ $CLEANUP_DONE -eq 1 ]; then
            return
        fi

        RELEASED_CORES=$(
            # Reopen the file descriptor for flock
            exec 200>$CORE_FLOCK
            flock -x 200
            MY_CORES=$(grep "^$$," $CORE_PID_MAP 2>/dev/null | cut -d',' -f2-)
            if [ -n "$MY_CORES" ]; then
                ALLOCATED_CORES=$(cat $CORE_FILE 2>/dev/null || echo "")
                for CORE in $(echo $MY_CORES | tr ',' ' '); do
                    ALLOCATED_CORES=$(echo "$ALLOCATED_CORES" | tr ',' '\n' | grep -v "^$CORE$" | tr '\n' ',' | sed 's/^,//;s/,$//')
                done
                echo "$ALLOCATED_CORES" >$CORE_FILE
                sed -i "/^$$/d" "$CORE_PID_MAP" 2>/dev/null
            fi
            # Close the file descriptor
            exec 200>&-
            echo $MY_CORES
        )
        echo
        echo "Released cores: $RELEASED_CORES" >&2
        echo

        CLEANUP_DONE=1
    }

elif [ $NCPU -eq -1 ]; then
    # Explicit CPU list was provided
    echo "Using specific CPU cores: $CORES"
    cmd+=" taskset -c $CORES"
else
    echo "Using all available CPU cores"
fi

cleanup_temp_files() {
        # Remove temporary files
        rm -rf $TMPDIR
        rm -f $RSESSION_CONF
        rm -f $HOME/$VOL_LOCAL_ENTRY
}

cleanup_all() {
    if [ $NCPU -gt 0 ]; then
        cleanup_core_lock
    fi
    cleanup_temp_files
}
trap cleanup_all EXIT INT TERM

cmd+=" apptainer exec \\
    -B $TMPDIR/var/lib/rstudio-server:/var/lib/rstudio-server \\
    -B $TMPDIR/var/run/rstudio-server:/var/run/rstudio-server \\
    -B $TMPDIR/tmp:/tmp \\
    -B /vol/local:/home/rstudio/$VOL_LOCAL_ENTRY \\
    -B $RSESSION_CONF:/etc/rstudio/rsession.conf \\
    $SIF \\
    rserver --www-address=127.0.0.1 --www-port=$PORT \\
    --auth-none=0 \\
    --auth-pam-helper-path=pam-helper \\
    --server-user=$USER"

# Execute the command
echo
eval "$cmd"
