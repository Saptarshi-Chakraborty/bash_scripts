#!/bin/bash

# --- Configuration ---
# API Key will be read from environment variable UPLOADTHING_API_KEY
# To set it in your terminal before running:
# export UPLOADTHING_API_KEY="your_actual_api_key_here"

CURRENT_USERNAME=$(whoami)
MINECRAFT_PARENT_DIR="/home/${CURRENT_USERNAME}/minecraft_server"
FOLDER_TO_ARCHIVE="dbboys" # The folder name inside MINECRAFT_PARENT_DIR

# Uploadthing API details
UPLOADTHING_PREPARE_URL="https://api.uploadthing.com/v7/prepareUpload"
UPLOADTHING_POLL_URL_BASE="https://api.uploadthing.com/v6/pollUpload"

# Parameters for prepareUpload
UPLOAD_SLUG="minecraftBackupUploader"
CUSTOM_ID_PREFIX="dbboys-backup"
CONTENT_DISPOSITION="attachment"
ACL="public-read"
EXPIRES_IN_SECONDS=300

# Polling configuration
POLL_ATTEMPTS=6
POLL_INTERVAL_SECONDS=15
MAX_UPLOAD_TIME_SECONDS=720 # 12 minutes for the main upload curl command

# --- Helper Functions ---
log_message() {
    # Consistent log timestamp format
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
check_command_exists "tar"
check_command_exists "date"
check_command_exists "stat"

if [ -z "${UPLOADTHING_API_KEY}" ]; then
    log_message "Error: UPLOADTHING_API_KEY environment variable is not set."
    log_message "Please set it by running: export UPLOADTHING_API_KEY=\"your_api_key_here\""
    exit 1
fi

if [ ! -d "${MINECRAFT_PARENT_DIR}" ]; then
    log_message "Error: Minecraft parent directory not found: ${MINECRAFT_PARENT_DIR}"
    exit 1
fi

if [ ! -d "${MINECRAFT_PARENT_DIR}/${FOLDER_TO_ARCHIVE}" ]; then
    log_message "Error: Folder to archive not found: ${MINECRAFT_PARENT_DIR}/${FOLDER_TO_ARCHIVE}"
    exit 1
fi

# --- 1. Generate Timestamp and Filename ---
log_message "Generating timestamp and filename..."
TIMESTAMP_FILENAME=$(TZ="Asia/Kolkata" date +"%d%m%Y-%H%M")
ARCHIVE_FILENAME="dbboys-minecraft-server-${TIMESTAMP_FILENAME}.tar.gz"
ARCHIVE_FILEPATH="${MINECRAFT_PARENT_DIR}/${ARCHIVE_FILENAME}"
CUSTOM_ID="${CUSTOM_ID_PREFIX}-${TIMESTAMP_FILENAME}"

log_message "Archive will be named: ${ARCHIVE_FILENAME}"

# --- 2. Create .tar.gz Archive ---
log_message "Navigating to ${MINECRAFT_PARENT_DIR} to create archive..."
cd "${MINECRAFT_PARENT_DIR}" || {
    log_message "Error: Could not navigate to ${MINECRAFT_PARENT_DIR}"
    exit 1
}

log_message "Creating archive of '${FOLDER_TO_ARCHIVE}' as '${ARCHIVE_FILENAME}'..."
tar -czf "${ARCHIVE_FILENAME}" "${FOLDER_TO_ARCHIVE}"
if [ $? -ne 0 ]; then
    log_message "Error: Failed to create tar archive."
    exit 1
fi
log_message "Archive created successfully: ${ARCHIVE_FILEPATH}"

# --- 3. Calculate File Size ---
log_message "Calculating file size..."
FILE_SIZE=$(stat -c%s "${ARCHIVE_FILEPATH}")
if [ $? -ne 0 ] || [ -z "${FILE_SIZE}" ]; then
    log_message "Error: Failed to get file size for ${ARCHIVE_FILEPATH}"
    rm -f "${ARCHIVE_FILEPATH}"
    exit 1
fi
log_message "File size: ${FILE_SIZE} bytes"

# --- 4. Prepare Upload with Uploadthing (OMIT fileType) ---
log_message "Preparing upload with Uploadthing..."
JSON_DATA_FOR_PREPARE=$(printf '{
  "fileName": "%s",
  "fileSize": %s,
  "slug": "%s",
  "customId": "%s",
  "contentDisposition": "%s",
  "acl": "%s",
  "expiresIn": %s
}' "${ARCHIVE_FILENAME}" "${FILE_SIZE}" "${UPLOAD_SLUG}" "${CUSTOM_ID}" "${CONTENT_DISPOSITION}" "${ACL}" "${EXPIRES_IN_SECONDS}")

PREPARE_RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "X-Uploadthing-Api-Key: ${UPLOADTHING_API_KEY}" \
  --data "${JSON_DATA_FOR_PREPARE}" \
  "${UPLOADTHING_PREPARE_URL}")

if [ $? -ne 0 ]; then
    log_message "Error: curl command for prepareUpload failed."
    rm -f "${ARCHIVE_FILEPATH}"
    exit 1
fi

UPLOAD_URL=$(echo "${PREPARE_RESPONSE}" | jq -r '.url')
FILE_KEY=$(echo "${PREPARE_RESPONSE}" | jq -r '.key')
ERROR_MESSAGE_PREPARE=$(echo "${PREPARE_RESPONSE}" | jq -r '.error')

if [ "${UPLOAD_URL}" == "null" ] || [ -z "${UPLOAD_URL}" ] || [ "${FILE_KEY}" == "null" ] || [ -z "${FILE_KEY}" ]; then
    log_message "Error: Failed to get pre-signed URL or file key from Uploadthing."
    log_message "API Response: ${PREPARE_RESPONSE}"
    if [ "${ERROR_MESSAGE_PREPARE}" != "null" ] && [ -n "${ERROR_MESSAGE_PREPARE}" ]; then
        log_message "Uploadthing Error: ${ERROR_MESSAGE_PREPARE}"
    fi
    rm -f "${ARCHIVE_FILEPATH}"
    exit 1
fi

log_message "Pre-signed URL received (hidden for brevity)"
log_message "File Key: ${FILE_KEY}"

# --- 5. Upload the File ---
log_message "Uploading ${ARCHIVE_FILENAME} to Uploadthing..."
log_message "Upload URL: ${UPLOAD_URL}"

TEMP_CURL_RESPONSE_BODY_FILE="curl_upload_response_body.tmp"
TEMP_CURL_RESPONSE_HEADERS_FILE="curl_upload_response_headers.tmp"
UPLOAD_HTTP_STATUS_OUTPUT_FILE="curl_http_status.tmp"

curl --max-time "${MAX_UPLOAD_TIME_SECONDS}" \
     -L \
     -D "${TEMP_CURL_RESPONSE_HEADERS_FILE}" \
     -o "${TEMP_CURL_RESPONSE_BODY_FILE}" \
     -w "%{http_code}" \
     --request PUT \
     --progress-bar \
     -F "file=@${ARCHIVE_FILEPATH};type=application/gzip" \
     "${UPLOAD_URL}" > "${UPLOAD_HTTP_STATUS_OUTPUT_FILE}"
CURL_EXIT_CODE=$?
ACTUAL_UPLOAD_HTTP_STATUS=$(cat "${UPLOAD_HTTP_STATUS_OUTPUT_FILE}")
rm -f "${UPLOAD_HTTP_STATUS_OUTPUT_FILE}"

log_message "curl command for upload finished."
log_message "Curl Exit Code: ${CURL_EXIT_CODE}"
log_message "HTTP Status Code reported by curl -w: '${ACTUAL_UPLOAD_HTTP_STATUS}'"

if [ -f "${TEMP_CURL_RESPONSE_HEADERS_FILE}" ] && [ -s "${TEMP_CURL_RESPONSE_HEADERS_FILE}" ]; then
    log_message "--- Response Headers from Upload ---"
    # cat "${TEMP_CURL_RESPONSE_HEADERS_FILE}" # Can be noisy, enable if needed for deep debug
    head -n 5 "${TEMP_CURL_RESPONSE_HEADERS_FILE}" # Log first 5 lines of headers
    log_message "------------------------------------"
fi

UPLOAD_PROCEEDED_TO_POLLING=false
FINAL_FILE_URL="" # Initialize FINAL_FILE_URL

if [ ${CURL_EXIT_CODE} -eq 0 ]; then
    if [ "${ACTUAL_UPLOAD_HTTP_STATUS}" == "200" ]; then
        log_message "Upload successful: HTTP 200 OK received."
        UPLOAD_PROCEEDED_TO_POLLING=true
        if [ -f "${TEMP_CURL_RESPONSE_BODY_FILE}" ] && [ -s "${TEMP_CURL_RESPONSE_BODY_FILE}" ]; then
            UPLOAD_RESPONSE_BODY=$(cat "${TEMP_CURL_RESPONSE_BODY_FILE}")
            log_message "Upload Response Body received." # Don't log full body unless debugging
            if echo "${UPLOAD_RESPONSE_BODY}" | jq -e . > /dev/null 2>&1; then
                FINAL_FILE_URL=$(echo "${UPLOAD_RESPONSE_BODY}" | jq -r '.url // .ufsUrl') # .url first, then .ufsUrl
                log_message "Parsed Final File URL from upload response: ${FINAL_FILE_URL}"
            else
                log_message "Upload response body was not valid JSON."
            fi
        else
            log_message "No response body file found or empty, but HTTP 200 received."
        fi
    else
        log_message "Error: Upload HTTP Status was ${ACTUAL_UPLOAD_HTTP_STATUS} (Curl Exit Code: 0)."
        if [ -f "${TEMP_CURL_RESPONSE_BODY_FILE}" ] && [ -s "${TEMP_CURL_RESPONSE_BODY_FILE}" ]; then
            log_message "--- Error Response Body from Upload ---"
            cat "${TEMP_CURL_RESPONSE_BODY_FILE}"
            log_message "---------------------------------------"
        fi
    fi
elif [ ${CURL_EXIT_CODE} -eq 28 ]; then
    log_message "Warning: Curl operation timed out (exit code 28) after ${MAX_UPLOAD_TIME_SECONDS} seconds."
    log_message "This often means the file was uploaded successfully, but the server did not respond in time."
    log_message "Proceeding to poll. VERIFY on Uploadthing dashboard using File Key: ${FILE_KEY}"
    UPLOAD_PROCEEDED_TO_POLLING=true
elif [ ${CURL_EXIT_CODE} -eq 2 ] || [ ${CURL_EXIT_CODE} -eq 130 ]; then
    log_message "Warning: Curl operation was interrupted by user (Ctrl+C - exit code ${CURL_EXIT_CODE})."
    log_message "Assuming file MIGHT have uploaded if progress was near 100%."
    log_message "Proceeding to poll. VERIFY on Uploadthing dashboard using File Key: ${FILE_KEY}"
    UPLOAD_PROCEEDED_TO_POLLING=true
else
    log_message "Error: curl command for file upload failed with unhandled exit code ${CURL_EXIT_CODE}."
fi

rm -f "${TEMP_CURL_RESPONSE_BODY_FILE}"
rm -f "${TEMP_CURL_RESPONSE_HEADERS_FILE}"

if [ "${UPLOAD_PROCEEDED_TO_POLLING}" = true ]; then
    if [ -z "${FILE_KEY}" ] || [ "${FILE_KEY}" == "null" ]; then
        log_message "CRITICAL ERROR: FILE_KEY is not set. Cannot poll."
        rm -f "${ARCHIVE_FILEPATH}"
        exit 1
    fi

    log_message "Proceeding to poll for file processing status."
    UPLOAD_COMPLETE=false
    for (( i=1; i<=POLL_ATTEMPTS; i++ )); do
        log_message "Poll attempt ${i}/${POLL_ATTEMPTS} for fileKey: ${FILE_KEY}"
        POLL_RESPONSE=$(curl -s -H "X-Uploadthing-Api-Key: ${UPLOADTHING_API_KEY}" \
            "${UPLOADTHING_POLL_URL_BASE}/${FILE_KEY}")

        if [ $? -ne 0 ]; then
            log_message "Warning: curl command for polling failed. Will retry."
            if [ $i -lt "${POLL_ATTEMPTS}" ]; then
                 sleep "${POLL_INTERVAL_SECONDS}"
            fi
            continue
        fi

        log_message "Raw Polling API Response: ${POLL_RESPONSE}"
        POLLING_STATUS=$(echo "${POLL_RESPONSE}" | jq -r '.status')
        # CORRECTED JQ PATH: .fileData.fileUrl
        FILE_URL_FROM_POLL=$(echo "${POLL_RESPONSE}" | jq -r '.fileData.fileUrl // .fileData.url // .fileData.ufsUrl')


        log_message "Extracted Polling Status: '${POLLING_STATUS}'"
        log_message "Extracted File URL from Poll: '${FILE_URL_FROM_POLL}'"

        # ADDED "done" to success statuses
        declare -a success_statuses=("Uploaded" "uploaded" "Completed" "Processed" "AVAILABLE" "complete" "done")
        IS_SUCCESS_STATUS=false
        for status_val in "${success_statuses[@]}"; do
            if [[ "${POLLING_STATUS}" == "${status_val}" ]]; then
                IS_SUCCESS_STATUS=true
                break
            fi
        done

        # Condition to break loop: status is success AND a URL is found
        if [ "${IS_SUCCESS_STATUS}" = true ] && [ "${FILE_URL_FROM_POLL}" != "null" ] && [ -n "${FILE_URL_FROM_POLL}" ]; then
            log_message "Polling Condition MET: Status is '${POLLING_STATUS}' AND File URL ('${FILE_URL_FROM_POLL}') is present."
            UPLOAD_COMPLETE=true
            FINAL_FILE_URL="${FILE_URL_FROM_POLL}" # Prioritize URL from poll if status is success
            break
        elif [ "${IS_SUCCESS_STATUS}" = true ]; then
            # If status is success but URL is somehow still null from this poll, log it but still count as complete.
            # We might have gotten the URL from the initial upload response if that was 200 OK.
            log_message "Polling Condition MET: Status is '${POLLING_STATUS}', but no File URL extracted from this specific poll response."
            UPLOAD_COMPLETE=true
            break
        else
            log_message "Polling conditions not met for breakout. Status: '${POLLING_STATUS}'."
        fi

        if [ $i -lt "${POLL_ATTEMPTS}" ]; then
            log_message "Upload processing or status not yet final per poll. Waiting ${POLL_INTERVAL_SECONDS} seconds..."
            sleep "${POLL_INTERVAL_SECONDS}"
        fi
    done

    if [ "${UPLOAD_COMPLETE}" = true ]; then
        log_message "File successfully uploaded and processed by Uploadthing!"
        if [ -n "${FINAL_FILE_URL}" ] && [ "${FINAL_FILE_URL}" != "null" ]; then
            log_message "Final File URL: ${FINAL_FILE_URL}"
        else
            # This case means upload + polling declared success, but we couldn't grab a URL.
            log_message "File processing is complete, but a final URL could not be determined from API responses."
            log_message "Please check the Uploadthing dashboard with File Key: ${FILE_KEY}"
        fi
        # DELETE LOCAL ARCHIVE upon successful processing
        log_message "Deleting local archive: ${ARCHIVE_FILEPATH}"
        rm -f "${ARCHIVE_FILEPATH}"
        if [ $? -eq 0 ]; then
            log_message "Local archive deleted successfully."
        else
            log_message "Warning: Failed to delete local archive ${ARCHIVE_FILEPATH}"
        fi
    else
        log_message "Warning: Upload did not reach a confirmed 'done' or 'success' status after ${POLL_ATTEMPTS} poll attempts."
        log_message "Please check the Uploadthing dashboard for file status using File Key: ${FILE_KEY}"
        log_message "Local archive ${ARCHIVE_FILEPATH} will NOT be deleted for safety."
    fi
else
    log_message "Upload process did not result in a state where polling could proceed. Halting script."
    log_message "Local archive ${ARCHIVE_FILEPATH} will NOT be deleted for safety."
    exit 1
fi

log_message "Script finished."
exit 0
