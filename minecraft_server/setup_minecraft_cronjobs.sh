#!/bin/bash

# This script sets up cron jobs for Minecraft backup and cleanup.

# --- Configuration (Adjust these if your scripts are elsewhere) ---
CURRENT_USERNAME=$(whoami)
USER_HOME_DIR=$(eval echo "~${CURRENT_USERNAME}") # More robust way to get home dir

# Assumes your scripts are in a 'scripts' subdirectory in the user's home.
# If they are directly in the home directory, change to:
# SCRIPT_DIR="${USER_HOME_DIR}"
SCRIPT_DIR="${USER_HOME_DIR}" # Example: /home/your_user
UPLOAD_SCRIPT_NAME="upload_minecraft_backup.sh"
MANAGE_SCRIPT_NAME="manage_minecraft_backups.sh"

# Log file locations (ensure the 'logs' directory exists or change path)
LOG_DIR="${USER_HOME_DIR}"
UPLOAD_LOG_FILE="${LOG_DIR}/minecraft_backup.log"
MANAGE_LOG_FILE="${LOG_DIR}/minecraft_cleanup.log"
# --- End Configuration ---

FULL_UPLOAD_SCRIPT_PATH="${SCRIPT_DIR}/${UPLOAD_SCRIPT_NAME}"
FULL_MANAGE_SCRIPT_PATH="${SCRIPT_DIR}/${MANAGE_SCRIPT_NAME}"

log_message() {
    echo "[CRON SETUP - $(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# Function to check if a script-specific cron job already exists
# This is a basic check looking for the script path.
# A more robust check would parse the command more thoroughly.
cron_job_exists_for_script() {
    local script_path="$1"
    # crontab -l might fail if no crontab exists yet, 2>/dev/null handles this
    if crontab -l 2>/dev/null | grep -Fq -- "${script_path}"; then
        return 0 # Job exists
    else
        return 1 # Job does not exist
    fi
}

# --- Main Script ---
log_message "Starting Minecraft cron job setup for user: ${CURRENT_USERNAME}"

# 1. Check if scripts exist and are executable
if [ ! -f "${FULL_UPLOAD_SCRIPT_PATH}" ]; then
    log_message "ERROR: Upload script not found at ${FULL_UPLOAD_SCRIPT_PATH}"
    log_message "Please ensure it exists and the SCRIPT_DIR path is correct in this setup script."
    exit 1
fi
if [ ! -x "${FULL_UPLOAD_SCRIPT_PATH}" ]; then
    log_message "ERROR: Upload script at ${FULL_UPLOAD_SCRIPT_PATH} is not executable."
    log_message "Please run: chmod +x ${FULL_UPLOAD_SCRIPT_PATH}"
    exit 1
fi

if [ ! -f "${FULL_MANAGE_SCRIPT_PATH}" ]; then
    log_message "ERROR: Manage/Cleanup script not found at ${FULL_MANAGE_SCRIPT_PATH}"
    log_message "Please ensure it exists and the SCRIPT_DIR path is correct in this setup script."
    exit 1
fi
if [ ! -x "${FULL_MANAGE_SCRIPT_PATH}" ]; then
    log_message "ERROR: Manage/Cleanup script at ${FULL_MANAGE_SCRIPT_PATH} is not executable."
    log_message "Please run: chmod +x ${FULL_MANAGE_SCRIPT_PATH}"
    exit 1
fi

# 2. Create log directory if it doesn't exist
if [ ! -d "${LOG_DIR}" ]; then
    log_message "Log directory ${LOG_DIR} does not exist. Creating it..."
    mkdir -p "${LOG_DIR}"
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to create log directory ${LOG_DIR}. Please create it manually."
        exit 1
    fi
    log_message "Log directory created."
fi

# 3. Get API Key
if [ -z "${UPLOADTHING_API_KEY_INPUT}" ]; then # Allow passing it as env for non-interactive
    read -r -p "Enter your Uploadthing API Key: " UPLOADTHING_API_KEY_INPUT
    echo "" # Newline after secret input
fi

if [ -z "${UPLOADTHING_API_KEY_INPUT}" ]; then
    log_message "ERROR: No Uploadthing API Key provided."
    exit 1
fi

# Define the exact cron job lines
# Remember: These times are based on the SYSTEM's timezone.
# If system is UTC, 2:00 AM IST is 20:30 UTC previous day.
# If system is UTC, 1:00 AM IST is 19:30 UTC previous day.
# If system is UTC, 1:00 PM IST is 07:30 UTC same day.
# The script will define jobs for 1AM, 2AM, 1PM as per system time.
# User should adjust these values if their system is UTC and they want IST times.
CRON_UPLOAD_JOB_LINE="0 2 * * * UPLOADTHING_API_KEY=\"${UPLOADTHING_API_KEY_INPUT}\" ${FULL_UPLOAD_SCRIPT_PATH} >> ${UPLOAD_LOG_FILE} 2>&1"
CRON_MANAGE_JOB_1AM_LINE="0 1 * * * UPLOADTHING_API_KEY=\"${UPLOADTHING_API_KEY_INPUT}\" ${FULL_MANAGE_SCRIPT_PATH} >> ${MANAGE_LOG_FILE} 2>&1"
CRON_MANAGE_JOB_1PM_LINE="0 13 * * * UPLOADTHING_API_KEY=\"${UPLOADTHING_API_KEY_INPUT}\" ${FULL_MANAGE_SCRIPT_PATH} >> ${MANAGE_LOG_FILE} 2>&1"

COMMENT_UPLOAD_JOB="# Minecraft Backup Job (via setup script)"
COMMENT_MANAGE_JOB="# Minecraft Cleanup Job (via setup script)"

# 4. Add jobs to crontab if they don't already exist targeting these scripts
CRON_TEMP_FILE=$(mktemp) || { log_message "Failed to create temp file"; exit 1; }
trap 'rm -f "${CRON_TEMP_FILE}"' EXIT # Ensure temp file is cleaned up

# Dump current crontab, or ensure temp file is empty if no crontab exists
crontab -l > "${CRON_TEMP_FILE}" 2>/dev/null

JOBS_ADDED=0

# Check and add Upload Job (2 AM)
if ! grep -Fq -- "${FULL_UPLOAD_SCRIPT_PATH}" "${CRON_TEMP_FILE}"; then
    log_message "Adding Minecraft backup job (2 AM) to crontab."
    echo "${COMMENT_UPLOAD_JOB}" >> "${CRON_TEMP_FILE}"
    echo "${CRON_UPLOAD_JOB_LINE}" >> "${CRON_TEMP_FILE}"
    JOBS_ADDED=$((JOBS_ADDED + 1))
else
    log_message "A cron job for ${FULL_UPLOAD_SCRIPT_PATH} already seems to exist. Skipping addition."
fi

# Check and add Manage Job (1 AM and 1 PM)
# This simple check might add the 1PM job if only the 1AM job exists for the same script.
# A more sophisticated check would verify the exact command line.
# For simplicity, we check if *any* job for FULL_MANAGE_SCRIPT_PATH exists.
# If you need distinct checks for 1 AM and 1 PM, the grep must be more specific.
# This version groups them: if any manage job exists, it skips adding more.

MANAGE_JOBS_EXIST=false
if grep -Fq -- "${FULL_MANAGE_SCRIPT_PATH}" "${CRON_TEMP_FILE}"; then
    MANAGE_JOBS_EXIST=true
fi

if [ "${MANAGE_JOBS_EXIST}" = false ]; then
    log_message "Adding Minecraft cleanup jobs (1 AM & 1 PM) to crontab."
    echo "${COMMENT_MANAGE_JOB}" >> "${CRON_TEMP_FILE}"
    echo "${CRON_MANAGE_JOB_1AM_LINE}" >> "${CRON_TEMP_FILE}"
    echo "${CRON_MANAGE_JOB_1PM_LINE}" >> "${CRON_TEMP_FILE}"
    JOBS_ADDED=$((JOBS_ADDED + 2)) # Counting as two jobs
else
    log_message "A cron job for ${FULL_MANAGE_SCRIPT_PATH} already seems to exist. Skipping the addition of 1AM/1PM cleanup jobs."
fi

# Add a blank line for separation if jobs were added
if [ "${JOBS_ADDED}" -gt 0 ]; then
    echo "" >> "${CRON_TEMP_FILE}"
    log_message "Applying changes to crontab..."
    crontab "${CRON_TEMP_FILE}"
    if [ $? -eq 0 ]; then
        log_message "Crontab updated successfully with ${JOBS_ADDED} new job(s)."
    else
        log_message "ERROR: Failed to update crontab."
    fi
else
    log_message "No new cron jobs were added as they (or jobs for the same scripts) seem to exist already."
fi

log_message "Setup finished."
log_message "Ensure your system's timezone is set correctly for the 1 AM, 2 AM, and 1 PM schedules."
log_message "To verify, run: crontab -l"
log_message "Log files will be created in: ${LOG_DIR}"

exit 0
