#!/bin/sh
set -eu

required_variables="SOURCE_FILE_URL DESTINATION_FILE_URL AZCOPY_MSI_CLIENT_ID"
for variable_name in $required_variables; do
    eval "variable_value=\${$variable_name:-}"
    if [ -z "$variable_value" ]; then
        echo "Missing required environment variable: $variable_name" >&2
        exit 64
    fi
done

case "$SOURCE_FILE_URL" in
    https://*.file.core.windows.net/*) ;;
    *) echo "SOURCE_FILE_URL must be an Azure Files HTTPS share URL." >&2; exit 64 ;;
esac

case "$DESTINATION_FILE_URL" in
    https://*.file.core.windows.net/*) ;;
    *) echo "DESTINATION_FILE_URL must be an Azure Files HTTPS share URL." >&2; exit 64 ;;
esac

if [ "$SOURCE_FILE_URL" = "$DESTINATION_FILE_URL" ]; then
    echo "Source and destination URLs must differ." >&2
    exit 64
fi

export AZCOPY_AUTO_LOGIN_TYPE=MSI
export AZCOPY_LOG_LOCATION="${AZCOPY_LOG_LOCATION:-/home/azcopy/.azcopy}"
export AZCOPY_JOB_PLAN_LOCATION="${AZCOPY_JOB_PLAN_LOCATION:-/home/azcopy/.azcopy}"

delete_destination="${DELETE_DESTINATION:-false}"
case "$delete_destination" in
    true|false|prompt) ;;
    *) echo "DELETE_DESTINATION must be true, false, or prompt." >&2; exit 64 ;;
esac

echo "Starting Azure Files synchronization. deleteDestination=$delete_destination"
set +e
azcopy sync "$SOURCE_FILE_URL" "$DESTINATION_FILE_URL" \
    --recursive=true \
    --delete-destination="$delete_destination" \
    --log-level="${AZCOPY_LOG_LEVEL:-INFO}" \
    --output-type=json
exit_code=$?
set -e

if [ "$exit_code" -ne 0 ]; then
    echo "AZURE_FILES_REPLICATION_FAILED exitCode=$exit_code" >&2
    exit "$exit_code"
fi

echo "AZURE_FILES_REPLICATION_SUCCEEDED"