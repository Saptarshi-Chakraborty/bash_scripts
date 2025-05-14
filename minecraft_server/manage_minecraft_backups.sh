#!/bin/bash

# --- Configuration ---
# API Key will be read from environment variable UPLOADTHING_API_KEY
# export UPLOADTHING_API_KEY="your_actual_api_key_here"

CURRENT_USERNAME=$(whoami)
MINECRAFT_PARENT_DIR="/home/${CURRENT_USERNAME}/minecraft_server"
ARCHIVE_PATTERN="dbboys-minecraft-server-*.tar.gz"
KEEP_LOCAL_BACKUPS=3    # Number of newest local backups to keep
KEEP_REMOTE_BACKUPS=1   # Number of newest remote backups to keep (will delete oldest if > this)

# Uploadthing API endpoints
USAGE_API_URL="https://api.uploadthing.com/v6/getUsageInfo" # For checking usage (optional here, but good to have)
LIST_FILES_API_URL="https://api.uploadthing.com/v6/listFiles"
DELETE_FILES_API_URL="https://api.uploadthing.com/v6/deleteFiles"

# --- Helper Functions ---
log_message() {
    echo "[$(TZ="Asia/Kolkata" date +"%Y-%m-%d %H:%M:%S")] $1"
}

check_command_exists() {
    command -v "$1" >/dev/null 2>&1 || {
        log_message "Error: Required command '$1' is not installed. Please install it and try again."
        exit 1
    }
}

# --- Sanity Checks ---
check_command_exists "curl"
check_command_exists "jq"
check_command_exists "ls"
check_command_exists "tail"
check_command_exists "wc"
check_command_exists "sort"
check_command_exists "date"

if [ -z "${UPLOADTHING_API_KEY}" ]; then
    log_message "Error: UPLOADTHING_API_KEY environment variable is not set."
    exit 1
fi

if [ ! -d "${MINECRAFT_PARENT_DIR}" ]; then
    log_message "Error: Minecraft parent directory not found: ${MINECRAFT_PARENT_DIR}"
    exit 1 # Exit if the main directory doesn't exist
fi

# --- Part 1: Local Backup Cleanup ---
log_message "--- Starting Local Backup Cleanup ---"
log_message "Target directory: ${MINECRAFT_PARENT_DIR}"
log_message "Keeping the ${KEEP_LOCAL_BACKUPS} newest local backups."

# List files by modification time (newest first), then select those to delete
# Using `find` is safer for filenames with spaces, but `ls -1t` is fine for this pattern
cd "${MINECRAFT_PARENT_DIR}" || { log_message "Error: Could not cd to ${MINECRAFT_PARENT_DIR}"; exit 1; }

# Count existing backups
BACKUP_FILES_COUNT=$(ls -1 ${ARCHIVE_PATTERN} 2>/dev/null | wc -l)

if [ "${BACKUP_FILES_COUNT}" -gt "${KEEP_LOCAL_BACKUPS}" ]; then
    log_message "Found ${BACKUP_FILES_COUNT} local backups. Deleting oldest ones..."
    # List files, sort by modification time (newest first using -t), skip the newest N (KEEP_LOCAL_BACKUPS)
    # and delete the rest. `tail -n +N` means start from Nth line. So N = KEEP_LOCAL_BACKUPS + 1
    FILES_TO_DELETE=$(ls -1t ${ARCHIVE_PATTERN} | tail -n +"$((KEEP_LOCAL_BACKUPS + 1))")

    if [ -n "${FILES_TO_DELETE}" ]; then
        echo "${FILES_TO_DELETE}" | while IFS= read -r file_to_delete; do
            log_message "Deleting local file: ${file_to_delete}"
            rm -f "${file_to_delete}"
            if [ $? -eq 0 ]; then
                log_message "Successfully deleted ${file_to_delete}"
            else
                log_message "Error deleting ${file_to_delete}"
            fi
        done
    else
        log_message "No old files identified for deletion (this is unexpected if count > keep)."
    fi
else
    log_message "Found ${BACKUP_FILES_COUNT} local backups. No local cleanup needed."
fi
log_message "--- Local Backup Cleanup Finished ---"
echo "" # Newline for readability

# --- Part 2: Uploadthing Remote Cleanup ---
log_message "--- Starting Uploadthing Remote Cleanup ---"
log_message "Keeping the ${KEEP_REMOTE_BACKUPS} newest remote backup(s)."

# 1. List remote files
log_message "Fetching list of remote files from Uploadthing..."
# Assuming we don't need pagination for this use case if we only care about a small number of files.
# The default limit for listFiles seems to be 500.
LIST_FILES_RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "X-Uploadthing-Api-Key: ${UPLOADTHING_API_KEY}" \
  --data "{}" \
  "${LIST_FILES_API_URL}")

CURL_LIST_EXIT_CODE=$?

if [ ${CURL_LIST_EXIT_CODE} -ne 0 ]; then
    log_message "Error: curl command to list files failed with exit code ${CURL_LIST_EXIT_CODE}."
    exit 1
fi

if ! echo "${LIST_FILES_RESPONSE}" | jq -e . > /dev/null 2>&1; then
    log_message "Error: API response for listFiles is not valid JSON: ${LIST_FILES_RESPONSE}"
    exit 1
fi

# Extract file list and count
# The response structure seems to be: {"files": [{"key": "...", "uploadedAt": timestamp_ms, ...}, ...]}
REMOTE_FILES_COUNT=$(echo "${LIST_FILES_RESPONSE}" | jq -r '.files | length')

if ! [[ "$REMOTE_FILES_COUNT" =~ ^[0-9]+$ ]]; then
    log_message "Error: Could not parse remote files count from API response: ${LIST_FILES_RESPONSE}"
    exit 1
fi

log_message "Found ${REMOTE_FILES_COUNT} file(s) on Uploadthing."

if [ "${REMOTE_FILES_COUNT}" -gt "${KEEP_REMOTE_BACKUPS}" ]; then
    NUMBER_TO_DELETE=$((REMOTE_FILES_COUNT - KEEP_REMOTE_BACKUPS))
    log_message "Need to delete ${NUMBER_TO_DELETE} oldest remote file(s)."

    # Get all files, sort by uploadedAt (oldest first), then take the first N to delete
    # jq 'sort_by(.uploadedAt)' sorts ascending (oldest first)
    # jq '.[0]' would take the very oldest. We need to iterate if NUMBER_TO_DELETE > 1
    # For "delete the oldest ONE if more than 1", we only need the absolute oldest.
    # The prompt implies deleting only *one* oldest if count > 1, not all but N.
    # "if the number of files is more than 1 , then delete the oldest one"

    # Let's stick to deleting only the single oldest file if count > KEEP_REMOTE_BACKUPS (which is 1)
    # This is safer and matches "delete the oldest one".
    # If KEEP_REMOTE_BACKUPS was, say, 3, and count was 5, we'd delete 2 oldest.
    # The prompt wording "if the number of files is more than 1, then delete the oldest one" means KEEP_REMOTE_BACKUPS=1.
    # If the intent was "keep N, delete others", the logic below would need a loop.
    # For now, targeting the single oldest if count > KEEP_REMOTE_BACKUPS.

    if [ "${NUMBER_TO_DELETE}" -gt 0 ]; then # Should always be true if REMOTE_FILES_COUNT > KEEP_REMOTE_BACKUPS
        log_message "Identifying the oldest file to delete..."
        # Sort by uploadedAt (ascending, so oldest is first), take the first element, then its 'key'.
        OLDEST_FILE_KEY=$(echo "${LIST_FILES_RESPONSE}" | jq -r '.files | sort_by(.uploadedAt) | .[0].key')
        OLDEST_FILE_NAME=$(echo "${LIST_FILES_RESPONSE}" | jq -r '.files | sort_by(.uploadedAt) | .[0].name')


        if [ "${OLDEST_FILE_KEY}" == "null" ] || [ -z "${OLDEST_FILE_KEY}" ]; then
            log_message "Error: Could not determine the key of the oldest file."
            log_message "API Response: ${LIST_FILES_RESPONSE}"
        else
            log_message "Oldest file identified for deletion: Name='${OLDEST_FILE_NAME}', Key='${OLDEST_FILE_KEY}'"

            # 2. Delete the oldest file
            JSON_DATA_FOR_DELETE=$(printf '{"fileKeys": ["%s"]}' "${OLDEST_FILE_KEY}")
            log_message "Attempting to delete remote file with key: ${OLDEST_FILE_KEY}"

            DELETE_RESPONSE=$(curl -s -X POST \
              -H "Content-Type: application/json" \
              -H "X-Uploadthing-Api-Key: ${UPLOADTHING_API_KEY}" \
              --data "${JSON_DATA_FOR_DELETE}" \
              "${DELETE_FILES_API_URL}")

            CURL_DELETE_EXIT_CODE=$?
            if [ ${CURL_DELETE_EXIT_CODE} -ne 0 ]; then
                log_message "Error: curl command to delete file failed with exit code ${CURL_DELETE_EXIT_CODE}."
            else
                log_message "Delete API Response: ${DELETE_RESPONSE}"
                # Check for success in the response, e.g., {"success": true, "deletedCount": 1}
                DELETE_SUCCESS=$(echo "${DELETE_RESPONSE}" | jq -r '.success')
                DELETED_COUNT=$(echo "${DELETE_RESPONSE}" | jq -r '.deletedCount')
                if [ "${DELETE_SUCCESS}" == "true" ] && [ "${DELETED_COUNT}" -ge 1 ]; then
                    log_message "Successfully deleted remote file: ${OLDEST_FILE_NAME} (Key: ${OLDEST_FILE_KEY})"
                else
                    log_message "Error: Failed to delete remote file or unexpected response. Success: '${DELETE_SUCCESS}', Count: '${DELETED_COUNT}'"
                fi
            fi
        fi
    fi # End if NUMBER_TO_DELETE > 0
else
    log_message "No remote cleanup needed based on current file count."
fi
log_message "--- Uploadthing Remote Cleanup Finished ---"

log_message "Cleanup script finished."
exit 0
