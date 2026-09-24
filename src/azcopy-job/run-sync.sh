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

# A scheduled job cannot answer AzCopy prompts, so prompt is not accepted.
delete_destination="${DELETE_DESTINATION:-false}"
case "$delete_destination" in
    true|false) ;;
    *) echo "DELETE_DESTINATION must be true or false." >&2; exit 64 ;;
esac

dry_run="${DRY_RUN:-false}"
case "$dry_run" in
    true|false) ;;
    *) echo "DRY_RUN must be true or false." >&2; exit 64 ;;
esac

preserve_permissions="${PRESERVE_PERMISSIONS:-true}"
case "$preserve_permissions" in
    true|false) ;;
    *) echo "PRESERVE_PERMISSIONS must be true or false." >&2; exit 64 ;;
esac

# File paths can be sensitive, so URLs are removed from diagnostics written to job logs.
redact_urls() {
    sed -E 's#https?://[^[:space:]"]+#<redacted-url>#g'
}

print_azcopy_log_tail() {
    for log_file in $(ls -t "$AZCOPY_LOG_LOCATION"/*.log 2>/dev/null | head -n 2); do
        echo "AzCopy log tail: $(basename "$log_file")" >&2
        tail -n 20 "$log_file" | redact_urls >&2 || true
    done
}

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_epoch="$(date -u +%s)"

elapsed_seconds() {
    echo $(( $(date -u +%s) - started_epoch ))
}

# AzCopy defaults --preserve-info to false for Linux SMB share-to-share copies.
set -- sync "$SOURCE_FILE_URL" "$DESTINATION_FILE_URL" \
    --recursive=true \
    --delete-destination="$delete_destination" \
    --preserve-info=true \
    --preserve-permissions="$preserve_permissions" \
    --include-root=true \
    --force-if-read-only=true \
    --log-level="${AZCOPY_LOG_LEVEL:-ERROR}"

echo "Starting Azure Files synchronization. dryRun=$dry_run deleteDestination=$delete_destination preservePermissions=$preserve_permissions"

if [ "$dry_run" = "true" ]; then
    # Dry runs report counts instead of one log line per file.
    dry_run_output="$(mktemp)"
    set +e
    azcopy "$@" --dry-run --output-type=text > "$dry_run_output" 2>&1
    exit_code=$?
    set -e

    would_copy="$(grep -c '^DRYRUN: copy ' "$dry_run_output" || true)"
    would_remove="$(grep -c '^DRYRUN: remove ' "$dry_run_output" || true)"
    would_set_properties="$(grep -c '^DRYRUN: set-properties ' "$dry_run_output" || true)"
    grep -v '^DRYRUN: ' "$dry_run_output" | tail -n 20 | redact_urls || true
    rm -f "$dry_run_output"

    summary="wouldCopy=$would_copy wouldRemove=$would_remove wouldSetProperties=$would_set_properties startedAt=$started_at durationSeconds=$(elapsed_seconds)"
    if [ "$exit_code" -ne 0 ]; then
        print_azcopy_log_tail
        echo "AZURE_FILES_REPLICATION_DRY_RUN_FAILED exitCode=$exit_code $summary" >&2
        exit "$exit_code"
    fi

    echo "AZURE_FILES_REPLICATION_DRY_RUN_COMPLETED $summary"
    exit 0
fi

set +e
azcopy "$@" --output-type=json
exit_code=$?
set -e

if [ "$exit_code" -ne 0 ]; then
    print_azcopy_log_tail
    echo "AZURE_FILES_REPLICATION_FAILED exitCode=$exit_code startedAt=$started_at durationSeconds=$(elapsed_seconds)" >&2
    exit "$exit_code"
fi

echo "AZURE_FILES_REPLICATION_SUCCEEDED startedAt=$started_at durationSeconds=$(elapsed_seconds)"