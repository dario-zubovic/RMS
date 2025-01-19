#!/bin/bash

# This script updates the RMS code from GitHub.
# Includes error handling, retries, and ensures critical files are never lost.

# Directories, files, and variables
RMSSOURCEDIR=~/source/RMS
RMSBACKUPDIR=~/.rms_backup
CURRENT_CONFIG="$RMSSOURCEDIR/.config"
CURRENT_MASK="$RMSSOURCEDIR/mask.bmp"
BACKUP_CONFIG="$RMSBACKUPDIR/.config"
BACKUP_MASK="$RMSBACKUPDIR/mask.bmp"
UPDATEINPROGRESSFILE=$RMSBACKUPDIR/update_in_progress
LOCKFILE="/tmp/update.lock"
MIN_SPACE_MB=200  # Minimum required space in MB
RETRY_LIMIT=3

# Function to check available disk space
check_disk_space() {
    local dir=$1
    local required_mb=$2
    
    # Get available space in KB and convert to MB
    local available_mb=$(df -P "$dir" | awk 'NR==2 {print $4/1024}' | cut -d. -f1)
    
    if [ "$available_mb" -lt "$required_mb" ]; then
        echo "Error: Insufficient disk space in $dir. Need ${required_mb}MB, have ${available_mb}MB"
        return 1
    fi
    return 0
}

# Run space check before anything else
echo "Checking available disk space..."
check_disk_space || exit 1

# Function to clean up and release the lock on exit
cleanup() {
    rm -f "$LOCKFILE"
}

# Ensure only one instance of the script runs at a time
if [ -f "$LOCKFILE" ]; then
    # Read the PID from the lock file
    LOCK_PID=$(cat "$LOCKFILE")
    
    # Check if the process is still running
    if ps -p "$LOCK_PID" > /dev/null 2>&1; then
        echo "Another instance of the script is already running. Exiting."
        exit 1
    else
        echo "Stale lock file found. Removing it and continuing."
        rm -f "$LOCKFILE"
    fi
fi

# Create a lock file with the current process ID
echo $$ > "$LOCKFILE"
trap cleanup EXIT

# Retry mechanism for critical file operations
retry_cp() {
    local src=$1
    local dest=$2
    local temp_dest="${dest}.tmp"
    local retries=0

    while [ $retries -lt $RETRY_LIMIT ]; do
        if cp "$src" "$temp_dest"; then
            # Validate the copied file
            if diff "$src" "$temp_dest" > /dev/null; then
                mv "$temp_dest" "$dest"
                return 0
            else
                echo "Error: Validation failed. Retrying..."
                rm -f "$temp_dest"
            fi
        else
            echo "Error: Copy failed. Retrying..."
            rm -f "$temp_dest"
        fi
        retries=$((retries + 1))
        sleep 1
    done

    echo "Critical Error: Failed to copy $src to $dest after $RETRY_LIMIT retries."
    return 1
}

# Backup files
backup_files() {
    echo "Backing up original files..."

    # Backup .config
    if [ -f "$CURRENT_CONFIG" ]; then
        if ! retry_cp "$CURRENT_CONFIG" "$BACKUP_CONFIG"; then
            echo "Critical Error: Could not back up .config file. Aborting."
            exit 1
        fi
    else
        echo "No original .config found. Generic config will be used."
    fi

    # Backup mask.bmp
    if [ -f "$CURRENT_MASK" ]; then
        if ! retry_cp "$CURRENT_MASK" "$BACKUP_MASK"; then
            echo "Critical Error: Could not back up mask.bmp file. Aborting."
            exit 1
        fi
    else
        echo "No original mask.bmp found. Blank mask will be used."
    fi
}

# Restore files
restore_files() {
    echo "Restoring configuration and mask files..."

    # Restore .config
    if [ -f "$BACKUP_CONFIG" ]; then
        if ! retry_cp "$BACKUP_CONFIG" "$CURRENT_CONFIG"; then
            echo "Critical Error: Failed to restore .config. Aborting."
            exit 1
        fi
    else
        echo "No backup .config found - a new one will be created by the installation."
    fi

    # Restore mask.bmp
    if [ -f "$BACKUP_MASK" ]; then
        if ! retry_cp "$BACKUP_MASK" "$CURRENT_MASK"; then
            echo "Critical Error: Failed to restore mask.bmp. Aborting."
            exit 1
        fi
    else
        echo "No backup mask.bmp found - a new blank mask will be created by the installation."
    fi
}
# Ensure the backup directory exists
mkdir -p "$RMSBACKUPDIR"

# Check if the update was interrupted previously
UPDATEINPROGRESS="0"
if [ -f "$UPDATEINPROGRESSFILE" ]; then
    echo "Reading update in progress file..."
    UPDATEINPROGRESS=$(cat "$UPDATEINPROGRESSFILE")
    echo "Update interruption status: $UPDATEINPROGRESS"
fi

# Backup files before any modifications
if [ "$UPDATEINPROGRESS" = "0" ]; then
    backup_files
else
    echo "Skipping backup due to interrupted update state."
fi

# Change to the RMS source directory
cd "$RMSSOURCEDIR" || { echo "Error: RMS source directory not found. Exiting."; exit 1; }

# Activate the virtual environment
if [ -f ~/vRMS/bin/activate ]; then
    source ~/vRMS/bin/activate
else
    echo "Error: Virtual environment not found. Exiting."
    exit 1
fi

# Perform cleanup operations before updating
echo "Removing the build directory..."
rm -rf build

echo "Cleaning up Python bytecode files..."
if command -v pyclean >/dev/null 2>&1; then
    pyclean . -v --debris all
else
    echo "pyclean not found, using basic cleanup..."
    # Remove .pyc files
    find . -name "*.pyc" -type f -delete
    # Remove __pycache__ directories
    find . -type d -name "__pycache__" -exec rm -r {} +
    # Remove .pyo files if they exist
    find . -name "*.pyo" -type f -delete
fi

echo "Cleaning up *.so files in the repository..."
find . -name "*.so" -type f -delete

# Mark the update as in progress
echo "1" > "$UPDATEINPROGRESSFILE"

# Stash any local changes
echo "Stashing local changes..."
git stash

# Pull the latest code from GitHub
echo "Pulling latest code from GitHub..."
git pull

# Create template from the current default config file
if [ -f "$CURRENT_CONFIG" ]; then
    echo "Creating config template..."
    mv "$CURRENT_CONFIG" "$RMSSOURCEDIR/.configTemplate"
    
    # Verify the move worked
    if [ ! -f "$RMSSOURCEDIR/.configTemplate" ]; then
        echo "Warning: Failed to verify config template creation"
    else
        echo "Config template created successfully"
    fi
fi

# Install missing dependencies
install_missing_dependencies() {
    local packages=(
        "gobject-introspection"
        "libgirepository1.0-dev"
        "gstreamer1.0-libav"
        "gstreamer1.0-plugins-bad"
    )
    local missing_packages=()

    # Identify missing packages
    for package in "${packages[@]}"; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done

    # If no missing packages, inform and return
    if [ ${#missing_packages[@]} -eq 0 ]; then
        echo "All required packages are already installed."
        return
    fi

    echo "The following packages are missing and will be installed: ${missing_packages[*]}"

    if sudo -n true 2>/dev/null; then
        echo "Passwordless sudo available. Installing missing packages..."
        sudo apt-get update
        for package in "${missing_packages[@]}"; do
            if ! sudo apt-get install -y "$package"; then
                echo "Failed to install $package. Please install it manually."
            fi
        done
    else
        echo "sudo privileges required. Prompting for password."
        sudo apt-get update
        for package in "${missing_packages[@]}"; do
            if ! sudo apt-get install -y "$package"; then
                echo "Failed to install $package. Please install it manually."
            fi
        done
    fi
}

install_missing_dependencies

# Install Python requirements
pip install -r requirements.txt

# Run the Python setup
python setup.py install

# Restore files after updates
restore_files

# Mark the update as completed
echo "0" > "$UPDATEINPROGRESSFILE"

echo "Update process completed successfully! Exiting in 5 seconds..."
sleep 5
