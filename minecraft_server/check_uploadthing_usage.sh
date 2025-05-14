#!/bin/bash

# --- Configuration ---
# API Key will be read from environment variable UPLOADTHING_API_KEY
# export UPLOADTHING_API_KEY="your_actual_api_key_here"

# User's stated account limit
USER_LIMIT_GB=2
USER_LIMIT_BYTES=$((USER_LIMIT_GB * 1024 * 1024 * 1024)) # 2 GiB in bytes

# Uploadthing API endpoint for usage info
USAGE_API_URL="https://api.uploadthing.com/v6/getUsageInfo"

# Warning threshold (percentage)
WARNING_THRESHOLD_PERCENT=80

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

bytes_to_human_readable() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then
        echo "0 B"
        return
    fi
    # Using awk for more precise floating point division and printf
    echo "$bytes" | awk '{
        bytes = $1;
        if (bytes == 0) { print "0 B"; exit }
        gib = bytes / (1024*1024*1024);
        mib = bytes / (1024*1024);
        kib = bytes / 1024;
        if (gib >= 1) {
            printf "%.2f GiB\n", gib;
        } else if (mib >= 1) {
            printf "%.2f MiB\n", mib;
        } else if (kib >= 1) {
            printf "%.2f KiB\n", kib;
        } else {
            printf "%d B\n", bytes;
        }
    }'
}


# --- Sanity Checks ---
check_command_exists "curl"
check_command_exists "jq"
check_command_exists "bc" # Still used for percentage calculation
check_command_exists "awk" # Used in bytes_to_human_readable
check_command_exists "date"

if [ -z "${UPLOADTHING_API_KEY}" ]; then
    log_message "Error: UPLOADTHING_API_KEY environment variable is not set."
    log_message "Please set it by running: export UPLOADTHING_API_KEY=\"your_api_key_here\""
    exit 1
fi

# --- Fetch Usage Information ---
log_message "Fetching Uploadthing usage information..."

# Using an array for curl arguments can be more robust
CURL_ARGS=(
    -s # Silent mode
    -X POST
    -H "Content-Type: application/json"
    -H "X-Uploadthing-Api-Key: ${UPLOADTHING_API_KEY}"
    --data "{}" # Empty JSON body for POST
    "${USAGE_API_URL}"
)

# Execute curl
API_RESPONSE=$(curl "${CURL_ARGS[@]}")
CURL_EXIT_CODE=$?

if [ ${CURL_EXIT_CODE} -ne 0 ]; then
    log_message "Error: curl command to fetch usage info failed with exit code ${CURL_EXIT_CODE}."
    log_message "Attempted to call: curl ${CURL_ARGS[*]}" # Log the command attempted
    exit 1
fi

if [ -z "${API_RESPONSE}" ]; then
    log_message "Error: Received empty response from Uploadthing API."
    exit 1
fi

log_message "Raw API Response: ${API_RESPONSE}"

# --- Parse API Response ---
# Validate if API_RESPONSE is valid JSON before proceeding
if ! echo "${API_RESPONSE}" | jq -e . > /dev/null 2>&1; then
    log_message "Error: API response is not valid JSON."
    exit 1
fi

TOTAL_BYTES_USED=$(echo "${API_RESPONSE}" | jq -r '.appTotalBytes // .totalBytes // 0')
FILES_UPLOADED=$(echo "${API_RESPONSE}" | jq -r '.filesUploaded // 0')
API_LIMIT_BYTES=$(echo "${API_RESPONSE}" | jq -r '.limitBytes // "null"')

if ! [[ "$TOTAL_BYTES_USED" =~ ^[0-9]+$ ]] || ! [[ "$FILES_UPLOADED" =~ ^[0-9]+$ ]]; then
    log_message "Error: Failed to parse numeric usage data from API response."
    log_message "Total Bytes Used (raw from jq): $TOTAL_BYTES_USED"
    log_message "Files Uploaded (raw from jq): $FILES_UPLOADED"
    exit 1
fi

# --- Display Usage Information ---
log_message "--- Uploadthing Account Usage ---"
log_message "Files Uploaded: ${FILES_UPLOADED}"

TOTAL_USED_HR=$(bytes_to_human_readable "${TOTAL_BYTES_USED}")
log_message "Total Storage Used: ${TOTAL_USED_HR} (${TOTAL_BYTES_USED} bytes)"

USER_LIMIT_HR=$(bytes_to_human_readable "${USER_LIMIT_BYTES}")
log_message "Your Stated Limit: ${USER_LIMIT_HR} (${USER_LIMIT_BYTES} bytes)"

if [ "${API_LIMIT_BYTES}" != "null" ] && [[ "${API_LIMIT_BYTES}" =~ ^[0-9]+$ ]]; then
    API_LIMIT_HR=$(bytes_to_human_readable "${API_LIMIT_BYTES}")
    log_message "API Reported Limit: ${API_LIMIT_HR} (${API_LIMIT_BYTES} bytes)"
else
    log_message "API Reported Limit: Not available or not parsed."
fi

# --- Calculate and Display Percentage Used (based on user's 2GB limit) ---
if [ "${USER_LIMIT_BYTES}" -gt 0 ]; then
    # Use awk for more robust percentage calculation
    PERCENTAGE_USED=$(awk -v total="${TOTAL_BYTES_USED}" -v limit="${USER_LIMIT_BYTES}" \
                        'BEGIN {if (limit == 0) {print "0.00"} else {printf "%.2f", (total * 100) / limit}}')

    log_message "Percentage of Your Stated Limit Used: ${PERCENTAGE_USED}%"

    WARNING_THRESHOLD_REACHED=$(awk -v percent="${PERCENTAGE_USED}" -v threshold="${WARNING_THRESHOLD_PERCENT}" \
                                 'BEGIN {print (percent >= threshold)}')
    LIMIT_REACHED=$(awk -v percent="${PERCENTAGE_USED}" 'BEGIN {print (percent >= 100)}')


    if [ "${LIMIT_REACHED}" -eq 1 ]; then
        log_message ""
        log_message "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log_message "!!! CRITICAL: Storage usage has REACHED or EXCEEDED your stated limit !!!"
        log_message "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    elif [ "${WARNING_THRESHOLD_REACHED}" -eq 1 ]; then
        log_message ""
        log_message "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log_message "!!! WARNING: Storage usage is at or above ${WARNING_THRESHOLD_PERCENT}% of your stated limit !!!"
        log_message "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi
else
    log_message "Cannot calculate percentage as user limit is 0."
fi

log_message "Script finished."
exit 0 
