#!/usr/bin/with-contenv bashio

# --- SETUP ---

# fail "loudly" on errors to be able to detect reoccuring issues
# note: requires checks eg to not make some FTP connection issue fail the whole script
set -euo pipefail

# basic constants
SRC="/backup"
SHARE_ROOT="/share"
FTPS_STATE_DIR="/data/ftps_uploaded"  # tracks files uploaded to server, survives restarts as /data is persistent

# local copy config
LOCAL_COPY_ENABLED=$(bashio::config 'local_copy_enabled')
LOCAL_COPY_SUBDIR=$(bashio::config 'local_copy_subdir')
# sanitize: strip leading and trailing slashes
LOCAL_COPY_SUBDIR="${LOCAL_COPY_SUBDIR#/}"
LOCAL_COPY_SUBDIR="${LOCAL_COPY_SUBDIR%/}"
# sanitize: reject any ".." path segments to prevent escaping root
if [[ "$LOCAL_COPY_SUBDIR" == *".."* ]]; then
	bashio::log.warning "local_copy_subdir contains '..', ignoring it"
    LOCAL_COPY_SUBDIR=""
fi
# never use the "/share" root directly, as sync would remove unrelated *.tar files there
if [ -z "$LOCAL_COPY_SUBDIR" ]; then
	LOCAL_COPY_SUBDIR="backups"
    bashio::log.warning "local_copy_subdir is empty or invalid, using default '${LOCAL_COPY_SUBDIR}'"
fi
DEST="${SHARE_ROOT}/${LOCAL_COPY_SUBDIR}"
# log status of local copy, ensure target folder exists
if [ "$LOCAL_COPY_ENABLED" = "true" ]; then
    mkdir -p "$DEST"
    bashio::log.info "Local copy enabled: ${SRC} -> ${DEST}"
else
    bashio::log.info "Local copy disabled"
fi

# FTPs upload configuration
FTPS_ENABLED=$(bashio::config 'ftps_enabled')
FTPS_HOST=$(bashio::config 'ftps_host')
FTPS_PORT=$(bashio::config 'ftps_port')
FTPS_IMPLICIT=$(bashio::config 'ftps_implicit')
FTPS_USER=$(bashio::config 'ftps_user')
FTPS_PASSWORD=$(bashio::config 'ftps_password')
FTPS_REMOTE_DIR=$(bashio::config 'ftps_remote_dir')
FTPS_VERIFY_CERT=$(bashio::config 'ftps_verify_cert')
FTPS_SYNC_DELETIONS=$(bashio::config 'ftps_sync_deletions')
# log status of FTPs upload, ensure folder for persistent upload tracking exists
if [ "$FTPS_ENABLED" = "true" ]; then
    if [ -z "$FTPS_HOST" ] || [ -z "$FTPS_USER" ] || [ -z "$FTPS_PASSWORD" ]; then
        bashio::log.warning "ftps upload enabled but missing host / user / password; disabling FTPS upload"
        FTPS_ENABLED="false"
    else
		bashio::log.info "FTPs upload enabled: ${FTPS_USER}@${FTPS_HOST}:${FTPS_PORT}${FTPS_REMOTE_DIR} (implicit=${FTPS_IMPLICIT}, verify_cert=${FTPS_VERIFY_CERT}, sync_deletions=${FTPS_SYNC_DELETIONS})"
        mkdir -p "$FTPS_STATE_DIR"
    fi
fi

# warn about ideling if both local copy and FTPs upload are disabled
if [ "$LOCAL_COPY_ENABLED" != "true" ] && [ "$FTPS_ENABLED" != "true" ]; then
    bashio::log.warning "Both local_copy_enabled and ftps_enabled are off; the add-on will watch ${SRC} but take no action on any file."
fi

# --- EVENTS ---

# fire Home Assistant event via Supervisor Core API proxy, which forwards authenticated requests to Core's /api/events/<event_type>
# note: addons get SUPERVISOR_TOKEN injected automatically
fire_event() {
    local event_type="$1"
    local payload="$2"

    if curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "http://supervisor/core/api/events/${event_type}" | grep -q "^200$"; then
        bashio::log.info "Fired event '${event_type}'"
    else
        bashio::log.warning "Failed to fire event '${event_type}' (Core may be unreachable)"
    fi
}

# --- FTP ---

# clean value for lftp command parser: wrap in double quotes, escape backslash and double quote
lftp_quote() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# prepare lftp prelude: protocol selection, cert verification, login, target dir.
# explicit FTPs uses the ftp:// scheme and upgrades via AUTH TLS while "ftp:ssl-force" makes lftp refuse to log in if the server does not support TLS (lftp would otherwise fall back to plain FTP and send the password in cleartext)
# implicit FTPs uses the ftps:// scheme, which negotiates TLS immediately on connect
ftps_prelude() {
    local scheme="ftp"
    if [ "$FTPS_IMPLICIT" = "true" ]; then
        scheme="ftps"
    fi
    cat <<EOF
set ssl:verify-certificate ${FTPS_VERIFY_CERT}
set ftp:ssl-force true
set ftp:ssl-protect-data true
set net:timeout 15
set net:max-retries 2
set net:reconnect-interval-base 5
set net:reconnect-interval-max 5
set cmd:fail-exit yes
open -p ${FTPS_PORT} $(lftp_quote "${scheme}://${FTPS_HOST}")
user $(lftp_quote "$FTPS_USER") $(lftp_quote "$FTPS_PASSWORD")
mkdir -p -f $(lftp_quote "$FTPS_REMOTE_DIR")
cd $(lftp_quote "$FTPS_REMOTE_DIR")
EOF
}

# run lftp commands with standard prelude
# note: script executes via stdin, so credentials never show up in the process list
ftps_run() {
    lftp -f /dev/stdin <<<"$(ftps_prelude)"$'\n'"$1"
}

# upload file to FTPs target dir, ie from $SRC
ftps_upload() {
	[ "$FTPS_ENABLED" = "true" ] || return 0

    local f="$1"
	local base now
    base=$(basename "$f")
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if ftps_run "put -O . $(lftp_quote "$f")"; then
        bashio::log.info "FTPs: uploaded ${base}"
		fire_event "new_backup_uploaded" "$(cat <<EOF
{"filename": "${base}", "path": "${FTPS_REMOTE_DIR}/${base}", "timestamp": "${now}"}
EOF
)"
        # keep local persistent track about upload done via empty file
        touch "${FTPS_STATE_DIR}/${base}" 2>/dev/null || true
    else
        bashio::log.error "FTPs: failed to upload ${base}"
		fire_event "new_backup_upload_failed" "$(cat <<EOF
{"filename": "${base}", "path": "${FTPS_REMOTE_DIR}/${base}", "timestamp": "${now}"}
EOF
)"
    fi
}

# remove file from FTPs target dir
ftps_delete() {
	[ "$FTPS_ENABLED" = "true" ] || return 0

    local base="$1"
    if ftps_run "rm -f $(lftp_quote "$base")"; then
        bashio::log.info "FTPs: deleted ${base}"
        rm -f -- "${FTPS_STATE_DIR}/${base}" 2>/dev/null || true
    else
        bashio::log.warning "FTPs: failed to delete ${base}"
    fi
}

# mirror deletions on FTPs server, ie remove any *.tar no longer existing in $SRC
ftps_sync_deletions() {
    [ "$FTPS_ENABLED" = "true" ] || return 0
    [ "$FTPS_SYNC_DELETIONS" = "true" ] || return 0

	# ensure sync does not delete all backup copies, if source does not exists or is (temporarily) not available
	source_without_backups || { bashio::log.warning "No backups in ${SRC}, skipping deletion sync"; return 0; }

	# get list of all .tar files in target path on server
    local listing
    listing=$(ftps_run "cls -1 *.tar" 2>/dev/null) || {
        bashio::log.warning "FTPs: could not list remote dir for deletion sync"
        return 0
    }

	# check through each list item, if the file (still) exists in source, delete if not (anymore)
    local remote_base
    while IFS= read -r remote_base; do
        [ -n "$remote_base" ] || continue
        if [ ! -f "${SRC}/${remote_base}" ]; then
            ftps_delete "$remote_base"
        fi
    done <<< "$listing"
}

# --- LOCAL ---

# local copy and verification, ie copy new file from $SRC to $DEST
local_copy() {
	[ "$LOCAL_COPY_ENABLED" = "true" ] || return 0

	local f="$1" base="$2" now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if ! { cp -f "$f" "${DEST}/${base}.tmp" && mv -f "${DEST}/${base}.tmp" "${DEST}/${base}"; }; then
		# remove leftovers in case copying fails
        rm -f -- "${DEST}/${base}.tmp"
		bashio::log.error "Failed to copy ${base}"
		fire_event "new_backup_copy_failed" "$(cat <<EOF
{"filename": "${base}", "path": "${DEST}/${base}", "timestamp": "${now}"}
EOF
)"
		return 1
	fi

	# verify copy by comparing file sizes as simple reliable integrity check
	local src_size dest_size
	src_size=$(stat -c%s "$f" 2>/dev/null || echo -1)
	dest_size=$(stat -c%s "${DEST}/${base}" 2>/dev/null || echo -2)
	if ! { [ "$src_size" -eq "$dest_size" ] && [ "$src_size" -gt 0 ]; }; then
		bashio::log.error "Size mismatch copying ${base}: src=${src_size} dest=${dest_size}"
		# remove bad copy so the resync loop retries later
        rm -f -- "${DEST}/${base}"
		fire_event "new_backup_copy_failed" "$(cat <<EOF
{"filename": "${base}", "path": "${DEST}/${base}", "timestamp": "${now}"}
EOF
)"
		return 1
	fi

    bashio::log.info "Copied and verified ${base} (${dest_size} bytes) to ${DEST}/${base}"
    fire_event "new_backup_copied" "$(cat <<EOF
{"filename": "${base}", "path": "${DEST}/${base}", "timestamp": "${now}"}
EOF
)"
    return 0
}

# mirror deletions in local target folder, ie remove any file from $DEST that no longer exists in $SRC
local_sync_deletions() {
    [ "$LOCAL_COPY_ENABLED" = "true" ] || return 0

	# ensure sync does not delete all backup copies, if source does not exists or is (temporarily) not available
	source_without_backups || { bashio::log.warning "No backups in ${SRC}, skipping deletion sync"; return 0; }

    local dest_file base
    for dest_file in "${DEST}"/*.tar; do
        [ -e "$dest_file" ] || continue
        base=$(basename "$dest_file")
        if [ ! -f "${SRC}/${base}" ]; then
            if rm -f -- "$dest_file"; then
                bashio::log.info "Local: deleted ${base}"
            else
                bashio::log.warning "Local: failed to delete ${base}"
            fi
        fi
    done
}

# --- COMMON / MONITORING ---

# ensure source exists and has at least has one *.tar file to prevent deletions when /backup is unmounted or temporarily empty
# note: prevents also deletion of last backup eg in case backups are disabled and deleted one by one
source_without_backups() {
    [ -d "$SRC" ] || return 1
    local -a tars
    shopt -s nullglob
    tars=("${SRC}"/*.tar)
    shopt -u nullglob
    [ "${#tars[@]}" -gt 0 ]
}

# process new file detected in $SRC
process_file() {
    local f="$1"
	# only act on *.tar backup files
    case "$f" in
        *.tar)
            local base
            base=$(basename "$f")
            bashio::log.info "Detected new backup: ${base}"

            # wait until file size is stable before acting, to avoid acting during creation
            # note: safety check for some cases where the file is "produced" in consecutive writes
            local required_quiet_seconds=5
            local poll_interval=1
            local max_wait_seconds=300
            local last_size=-1
            local last_mtime=-1
            local last_change_ts
            local now_ts
            local cur_size
            local cur_mtime
            local waited=0
            last_change_ts=$(date +%s)
            while true; do
                if [ ! -f "$f" ]; then
                    bashio::log.warning "${base} disappeared before processing, skipping"
                    return
                fi
                cur_size=$(stat -c%s "$f" 2>/dev/null || echo -1)
                cur_mtime=$(stat -c%Y "$f" 2>/dev/null || echo -1)
                now_ts=$(date +%s)
                if [ "$cur_size" != "$last_size" ] || [ "$cur_mtime" != "$last_mtime" ]; then
                    last_size="$cur_size"
                    last_mtime="$cur_mtime"
                    last_change_ts="$now_ts"
                fi
                if [ "$cur_size" -gt 0 ] && [ $((now_ts - last_change_ts)) -ge "$required_quiet_seconds" ]; then
                    break
                fi
                if [ "$waited" -ge "$max_wait_seconds" ]; then
                    bashio::log.warning "${base} did not reach a stable size after ${max_wait_seconds}s of waiting; processing anyway with last observed size ${cur_size} bytes"
                    break
                fi
                sleep "$poll_interval"
                waited=$((waited + poll_interval))
            done

			local_copy "$f" "$base" || true

            ftps_upload "$f"

            ;;
    esac
}

# watch for files fully written (close_write) or renamed/moved into place (moved_to) to $SRC
MAX_FAST_FAILURES=10  # number (reset to 0 upon first non-"fast" restart required)
FAST_FAILURE_WINDOW=30  # seconds (restart faster than this counts as "fast")
watch_backups() {
    local fast_failure_count=0
    local start_ts end_ts elapsed

    while true; do

		# resync in case events were missed while the watch was down
        for existing in "${SRC}"/*.tar; do
            [ -e "$existing" ] || continue
            base=$(basename "$existing")
            needs_action="false"
            if [ "$LOCAL_COPY_ENABLED" = "true" ] && [ ! -f "${DEST}/${base}" ]; then
                needs_action="true"
            fi
            if [ "$FTPS_ENABLED" = "true" ] && [ ! -f "${FTPS_STATE_DIR}/${base}" ]; then
                needs_action="true"
            fi
            if [ "$needs_action" = "true" ]; then
                process_file "$existing"
            fi
        done
        local_sync_deletions
        ftps_sync_deletions

		bashio::log.info "Start inotifywait watch on ${SRC}"
        start_ts=$(date +%s)

         # monitoring, should be running indefinitely
		inotifywait -m -e close_write -e moved_to --format '%f' "$SRC" | while IFS= read -r filename; do
			process_file "${SRC}/${filename}" || true
            local_sync_deletions || true
            ftps_sync_deletions || true
		done || true

        # handle unexpected exits of inotifywait which can happen in certain conditions
        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))
        # fast failure tracking vs once in a while hickup
        if [ "$elapsed" -lt "$FAST_FAILURE_WINDOW" ]; then
            fast_failure_count=$((fast_failure_count + 1))
			bashio::log.warning "inotifywait exited after only ${elapsed}s (fast failure ${fast_failure_count} of ${MAX_FAST_FAILURES})"
        else
			bashio::log.warning "inotifywait exited after ${elapsed}s; treating as transient, resetting fast failure count"
            fast_failure_count=0
        fi
        # terminate on serious issues with too many consecutive "fast" failures, ie a persistent problem, eg $SRC gone, inotify limits exhausted - visible within HA core as error
        if [ "$fast_failure_count" -ge "$MAX_FAST_FAILURES" ]; then
			bashio::log.error "inotifywait failed ${fast_failure_count} times in a row (each under ${FAST_FAILURE_WINDOW}s), ${SRC} might be missing / unmounted or inotify watch limit is exhausted"
            bashio::log.error "Exiting so add-on is marked as failed rather than retrying forever"
            exit 1
        fi

        sleep 5
    done
}

# let's get started
bashio::log.info "Backup Watcher starting..."
bashio::log.info "Watching ${SRC} for new backup files"
watch_backups
