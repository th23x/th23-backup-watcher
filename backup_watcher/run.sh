#!/usr/bin/with-contenv bashio

# --- SETUP ---

# fail "loudly" on errors to be able to detect reccuring issues
# note: requires checks eg to not make some FTP connection issue fail the whole script
set -euo pipefail

# basic constants
SRC="/backup"
SHARE_ROOT="/share"
FTPS_STATE_DIR="/data/ftps_uploaded"  # tracks files uploaded to server, survives restarts as /data is persistent
LOCAL_FREE_BYTES=$((1024 * 1024 * 1024))  # keep 1 GB of headroom on disk before creating local backup copies

# handle HA shutdown commands (instead waiting for a hard "kill")
CURRENT_TMP="" # temp file of a local copy in progress
CP_PID="" # background copy process of that local copy
# runs on every exit (stop request, fatal error, normal end): remove the partial copy still in progress
on_exit() {
    if [ -n "$CURRENT_TMP" ]; then
        rm -f -- "$CURRENT_TMP" 2>/dev/null || true
    fi
}
# runs on a stop request from Supervisor / Docker (SIGTERM) or Ctrl-C when testing manually (SIGINT)
on_stop() {
    bashio::log.info "Stop requested, shutting down"
    if [ -n "$CP_PID" ]; then
        kill "$CP_PID" 2>/dev/null || true
    fi
    exit 0  # runs the EXIT trap
}
trap on_stop SIGTERM SIGINT
trap on_exit EXIT

# security: allow unencrypted backups
ALLOW_UNENCRYPTED=$(bashio::config 'allow_unencrypted_backups')
if [ "$ALLOW_UNENCRYPTED" = "true" ]; then
    bashio::log.warning "allow_unencrypted_backups is on: Unencrypted backups (with secrets in plain text) will be copied / uploaded!"
else
    bashio::log.info "Only encrypted backups will be copied / uploaded"
fi

# local copy config
LOCAL_COPY_ENABLED=$(bashio::config 'local_copy_enabled')
LOCAL_COPY_SUBDIR=$(bashio::config 'local_copy_subdir')
# sanitize: strip leading and trailing slashes
LOCAL_COPY_SUBDIR="${LOCAL_COPY_SUBDIR#/}"
LOCAL_COPY_SUBDIR="${LOCAL_COPY_SUBDIR%/}"
# sanitize: reject any ".." path segments to prevent escaping root
LOCAL_COPY_CLEAN=""
IFS='/' read -ra SEGMENTS <<< "$LOCAL_COPY_SUBDIR"
for seg in "${SEGMENTS[@]}"; do
    case "$seg" in
        ""|".") continue ;;
        "..")
            bashio::log.warning "local_copy_subdir contains '..' as path segment, ignoring it"
            LOCAL_COPY_CLEAN=""
            break
            ;;
        *) LOCAL_COPY_CLEAN="${LOCAL_COPY_CLEAN:+${LOCAL_COPY_CLEAN}/}${seg}" ;;
    esac
done
LOCAL_COPY_SUBDIR="$LOCAL_COPY_CLEAN"
# never use the "/share" root directly, as sync would remove unrelated *.tar files there
if [ -z "$LOCAL_COPY_SUBDIR" ]; then
    LOCAL_COPY_SUBDIR="backups"
    bashio::log.warning "local_copy_subdir is empty or invalid, using default '${LOCAL_COPY_SUBDIR}'"
fi
DEST="${SHARE_ROOT}/${LOCAL_COPY_SUBDIR}"
# log status of local copy, ensure target folder exists
if [ "$LOCAL_COPY_ENABLED" = "true" ]; then
    mkdir -p "$DEST"
    # remove leftovers of a copy interrupted by a crash or kill (this app is the only writer)
    for stale in "${DEST}"/*.tar.tmp; do
        [ -e "$stale" ] || continue
        if rm -f -- "$stale"; then
            bashio::log.info "Local: removed stale temp file $(basename "$stale")"
        fi
    done
    bashio::log.info "Local copy enabled: ${SRC} -> ${DEST}"
else
    bashio::log.info "Local copy disabled"
fi
LOCAL_SYNC_DELETIONS=$(bashio::config 'local_sync_deletions')

# FTPs upload configuration
FTPS_ENABLED=$(bashio::config 'ftps_enabled')
FTPS_HOST=$(bashio::config 'ftps_host')
FTPS_PORT=$(bashio::config 'ftps_port')
FTPS_IMPLICIT=$(bashio::config 'ftps_implicit')
FTPS_USER=$(bashio::config 'ftps_user')
FTPS_PASSWORD=$(bashio::config 'ftps_password')
FTPS_REMOTE_DIR=$(bashio::config 'ftps_remote_dir')
FTPS_VERIFY_CERT=$(bashio::config 'ftps_verify_cert')
FTPS_CHECK_HOSTNAME=$(bashio::config 'ftps_check_hostname')
FTPS_CA_FILE=$(bashio::config 'ftps_ca_file')
# unset optional value comes back as "null", convert to empty string instead
if [ "$FTPS_CA_FILE" = "null" ]; then FTPS_CA_FILE=""; fi
# limit file name to inside the app's private configuration folder
if [ -n "$FTPS_CA_FILE" ]; then FTPS_CA_FILE="/config/${FTPS_CA_FILE}"; fi
FTPS_SYNC_DELETIONS=$(bashio::config 'ftps_sync_deletions')
# log status of FTPs upload and ensure folder for persistent upload tracking exists
if [ "$FTPS_ENABLED" = "true" ]; then
    if [ -z "$FTPS_HOST" ] || [ -z "$FTPS_USER" ] || [ -z "$FTPS_PASSWORD" ]; then
        bashio::log.warning "ftps upload enabled but missing host / user / password; disabling FTPS upload"
        FTPS_ENABLED="false"
    # note: also rejects theoretically valid files named eg "my..cert.pem"
    elif [ "$FTPS_VERIFY_CERT" = "true" ] && [ -n "$FTPS_CA_FILE" ] \
         && { [[ "$FTPS_CA_FILE" == *..* ]] \
              || ! { [ -r "$FTPS_CA_FILE" ] && grep -q 'BEGIN CERTIFICATE' "$FTPS_CA_FILE"; }; }; then
        bashio::log.error "ftps_ca_file must be the name of a PEM certificate inside the app's configuration folder (found: '${FTPS_CA_FILE}'); disabling FTPS upload"
        FTPS_ENABLED="false"
    elif [ "$FTPS_VERIFY_CERT" = "true" ] && [ "$FTPS_CHECK_HOSTNAME" != "true" ] && [ -z "$FTPS_CA_FILE" ]; then
		bashio::log.error "ftps_check_hostname can only be turned off together with a ftps_ca_file, otherwise any publicly trusted certificate would be accepted; disabling FTPS upload"
        FTPS_ENABLED="false"
    else
        bashio::log.info "FTPs upload enabled: ${FTPS_USER}@${FTPS_HOST}:${FTPS_PORT}${FTPS_REMOTE_DIR} (implicit=${FTPS_IMPLICIT}, verify_cert=${FTPS_VERIFY_CERT}, check_hostname=${FTPS_CHECK_HOSTNAME}, ca_file=${FTPS_CA_FILE:-system}, sync_deletions=${FTPS_SYNC_DELETIONS})"
        if [ "$FTPS_VERIFY_CERT" != "true" ]; then
            bashio::log.warning "ftps_verify_cert is off: password and backups are exposed to man-in-the-middle attacks. Use ftps_ca_file instead"
            [ -z "$FTPS_CA_FILE" ] || bashio::log.warning "ftps_ca_file is ignored while ftps_verify_cert is off"
        elif [ "$FTPS_CHECK_HOSTNAME" != "true" ]; then
            bashio::log.warning "ftps_check_hostname is off: the server name is not checked, only the certificate in ftps_ca_file is trusted. It must be the server's own certificate (or a CA you alone control)"
        fi
        mkdir -p "$FTPS_STATE_DIR"
    fi
fi
# remember remote server capabilities
FTPS_AVBL_SUPPORTED="unknown" # check free space
FTPS_SIZE_SUPPORTED="unknown" # check file size

# warn about idling if both local copy and FTPs upload are disabled
if [ "$LOCAL_COPY_ENABLED" != "true" ] && [ "$FTPS_ENABLED" != "true" ]; then
    bashio::log.warning "Both local_copy_enabled and ftps_enabled are off; the app will watch ${SRC} but take no action on any file."
fi

# --- EVENTS ---

# build the JSON payload of an event, jq takes care of escaping (quotes, backslashes, control characters)
# arguments: filename, path, timestamp and optionally a reason
event_payload() {
    local filename="$1" path="$2" timestamp="$3" reason="${4:-}"
    jq -nc --arg filename "$filename" --arg path "$path" --arg timestamp "$timestamp" --arg reason "$reason" \
        '{filename: $filename, path: $path, timestamp: $timestamp} + (if $reason != "" then {reason: $reason} else {} end)' \
        || echo '{}'
}

# fire Home Assistant event via Supervisor Core API proxy, which forwards authenticated requests to Core's /api/events/<event_type>
# note: apps get SUPERVISOR_TOKEN injected automatically
fire_event() {
    local event_type="$1"
    local payload="$2"

    if curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
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
    local scheme="ftp" ca_line=""
    if [ "$FTPS_IMPLICIT" = "true" ]; then
        scheme="ftps"
    fi
    if [ -n "$FTPS_CA_FILE" ]; then
        ca_line="set ssl:ca-file $(lftp_quote "$FTPS_CA_FILE")"
    fi
    cat <<EOF
set ssl:verify-certificate ${FTPS_VERIFY_CERT}
set ssl:check-hostname ${FTPS_CHECK_HOSTNAME}
${ca_line}
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

# ftp error classification; especially identify remote disk space constraints
ftps_classify_error() {
    if printf '%s' "$1" | grep -Eqi '(^|[^0-9])(452|552)([^0-9]|$)|disk full|quota|no space|insufficient storage'; then
        echo "insufficient_space"
    else
        echo "upload_error"
    fi
}

# check free space on remote server; fails with return 1 only if the server reports less free space than needed
# note: a server not supporting the AVBL command is remembered, connection or login problems do not change that
ftps_has_space() {
    [ "$FTPS_AVBL_SUPPORTED" != "no" ] || return 0

    local size="$1" out free
    # not reachable or login failed: no statement about AVBL support possible, the upload will report that problem
    if ! out=$(ftps_run "quote AVBL" 2>&1); then
        # a 5xx reply to the command itself means the server is reachable but lacks AVBL
        if printf '%s' "$out" | grep -Eq '(^|[^0-9])50[0-4]([^0-9]|$)'; then
            FTPS_AVBL_SUPPORTED="no"
            bashio::log.info "FTPs: server does not report free space"
        fi
        return 0
    fi

    free=$(printf '%s\n' "$out" | grep -Eo '213 [0-9]+' | tail -1 | awk '{print $2}')
    if ! [[ "$free" =~ ^[0-9]+$ ]]; then
        # server answered, but does not report free space
        FTPS_AVBL_SUPPORTED="no"
        bashio::log.info "FTPs: server does not report free space"
        return 0
    fi

    FTPS_AVBL_SUPPORTED="yes"
    if [ "$free" -lt "$size" ]; then
        bashio::log.error "FTPs: not enough space on server: need ${size}, have ${free}"
        return 1
    fi
}

# is an FTPs upload of file $1 (basename $2) required? (enabled?, never uploaded? changed since?)
# note: state file holds the fingerprint of the uploaded file
# important: files remotely deleted manually will NOT be re-uploaded
ftps_upload_needed() {
    [ "$FTPS_ENABLED" = "true" ] || return 1
    # ignore unencrypted backups, if not allowed
    if backup_blocked "$1"; then return 1; fi
    local state="${FTPS_STATE_DIR}/${2}"
    [ -f "$state" ] || return 0
    if [ ! -s "$state" ]; then
        # legacy empty state file: treat as uploaded and record the current fingerprint from now on
        file_fingerprint "$1" > "$state"
        return 1
    fi
    [ "$(cat "$state" 2>/dev/null)" != "$(file_fingerprint "$1")" ]
}

# upload file to FTPs target dir, ie from $SRC
ftps_upload() {
    [ "$FTPS_ENABLED" = "true" ] || return 0

    local f="$1"
    local base now size fp reason
    base=$(basename "$f")
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    fp=$(file_fingerprint "$f")

    # check sufficient space on remote target
    if ! ftps_has_space "$size"; then
        fire_event "new_backup_upload_failed" "$(event_payload "$base" "${FTPS_REMOTE_DIR}/${base}" "$now" "insufficient_space")"
        return 1
    fi

    # upload via temp name and rename, so the final name only ever points to a complete file
    # note: not inside $(...), as ftps_put_atomic hands the error text back in FTPS_ERROR
    if ftps_put_atomic "$f" "$base"; then
        bashio::log.info "FTPs: uploaded ${base}"
        fire_event "new_backup_uploaded" "$(event_payload "$base" "${FTPS_REMOTE_DIR}/${base}" "$now")"
        # keep persistent track of the upload: state file holds fingerprint of the uploaded file
        echo "$fp" > "${FTPS_STATE_DIR}/${base}" 2>/dev/null || true
    else
        # document reason for upload failure
        reason=$(ftps_classify_error "$FTPS_ERROR")
        bashio::log.error "FTPs: failed to upload ${base} (${reason}): $(printf '%s' "$FTPS_ERROR" | tail -n 3)"
        fire_event "new_backup_upload_failed" "$(event_payload "$base" "${FTPS_REMOTE_DIR}/${base}" "$now" "${reason}")"
    fi
}

# upload file $1 as $2: first under a temp name, so the final name only ever points to a complete file
# note: on failure the error text is left in FTPS_ERROR for the caller to classify and log
FTPS_ERROR=""
ftps_put_atomic() {
    local f="$1" base="$2" tmp="$2.tmp" out local_size remote_size
    FTPS_ERROR=""

    if ! out=$(ftps_run "put $(lftp_quote "$f") -o $(lftp_quote "$tmp")" 2>&1); then
        FTPS_ERROR="$out"
        ftps_run "rm -f $(lftp_quote "$tmp")" >/dev/null 2>&1 || true
        return 1
    fi

    # verify size, unless the server is known not to report it
    if [ "$FTPS_SIZE_SUPPORTED" != "no" ]; then
        local_size=$(stat -c%s "$f" 2>/dev/null || echo -1)
        if remote_size=$(ftps_remote_size "$tmp"); then
            FTPS_SIZE_SUPPORTED="yes"
            if [ "$remote_size" != "$local_size" ]; then
                FTPS_ERROR="size mismatch: local=${local_size} remote=${remote_size}"
                ftps_run "rm -f $(lftp_quote "$tmp")" >/dev/null 2>&1 || true
                return 1
            fi
        else
            # the server just accepted the upload, so assume it does not report sizes
            FTPS_SIZE_SUPPORTED="no"
            bashio::log.info "FTPs: server does not report file sizes, uploads are not verified"
        fi
    fi

    # try a plain rename first, remove an old version only if the server refuses to overwrite
    if ! out=$(ftps_run "mv $(lftp_quote "$tmp") $(lftp_quote "$base")" 2>&1); then
        ftps_run "rm -f $(lftp_quote "$base")" >/dev/null 2>&1 || true
        if ! out=$(ftps_run "mv $(lftp_quote "$tmp") $(lftp_quote "$base")" 2>&1); then
            FTPS_ERROR="$out"
            return 1
        fi
    fi
}

# size of remote file $1 in bytes (current remote dir); fails if the server does not answer SIZE
ftps_remote_size() {
    local out size
    out=$(ftps_run "quote SIZE $(lftp_quote "$1")" 2>/dev/null) || return 1
    size=$(printf '%s\n' "$out" | grep -Eo '213 [0-9]+' | tail -1 | awk '{print $2}')
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    echo "$size"
}

# mirror deletions on FTPs server, ie remove files this app uploaded (recorded in $FTPS_STATE_DIR) that no longer exist in $SRC
# note: all pending deletions share a single connection, without any pending deletion no connection is made
ftps_sync_deletions() {
    [ "$FTPS_ENABLED" = "true" ] || return 0
    [ "$FTPS_SYNC_DELETIONS" = "true" ] || return 0

    # ensure sync does not delete all backup copies, if source does not exist or is (temporarily) not available
    source_without_backups || { bashio::log.warning "No backups in ${SRC}, skipping deletion sync"; return 0; }

    local state_file base out listing script=""
    local -a pending=() present=()
    for state_file in "${FTPS_STATE_DIR}"/*; do
        [ -f "$state_file" ] || continue
        base=$(basename "$state_file")
        [[ "$base" == *.tar ]] || continue
        if [ -f "${SRC}/${base}" ]; then
            continue
        fi
        pending+=("$base")
    done

    [ "${#pending[@]}" -gt 0 ] || return 0

    # one listing tells which of OUR recorded files still exist on the server, nothing else is ever deleted
    if ! listing=$(ftps_run "cls -1" 2>/dev/null); then
        bashio::log.warning "FTPs: could not list remote dir, deletion sync will retry on next sync"
        return 0
    fi

    for base in "${pending[@]}"; do
        if printf '%s\n' "$listing" | grep -Fxq -- "$base"; then
            present+=("$base")
            script+="rm -f $(lftp_quote "$base")"$'\n'
        else
            # already gone from the server, only the record is left
            rm -f -- "${FTPS_STATE_DIR}/${base}" 2>/dev/null || true
            bashio::log.info "FTPs: ${base} already gone from server, dropped its record"
        fi
    done

    [ "${#present[@]}" -gt 0 ] || return 0

    if out=$(ftps_run "$script" 2>&1); then
        for base in "${present[@]}"; do
            bashio::log.info "FTPs: deleted ${base}"
            rm -f -- "${FTPS_STATE_DIR}/${base}" 2>/dev/null || true
        done
    else
        bashio::log.warning "FTPs: failed to delete ${#present[@]} file(s), will retry on next sync: $(printf '%s' "$out" | tail -n 3)"
    fi
}

# remove upload state files of backups that no longer exist in $SRC (local only, no network)
# note: with deletion sync enabled, ftps_sync_deletions already handles this
ftps_cleanup_state() {
    [ "$FTPS_ENABLED" = "true" ] || return 0
    if [ "$FTPS_SYNC_DELETIONS" = "true" ]; then
        return 0
    fi

    # same safeguard as the deletion syncs: do not wipe tracking if /backup is unmounted or empty
    source_without_backups || return 0

    local s
    for s in "${FTPS_STATE_DIR}"/*; do
        [ -f "$s" ] || continue
        [ -f "${SRC}/$(basename "$s")" ] || rm -f -- "$s"
    done
}

# --- LOCAL ---

# is a local copy of file $1 (basename $2) required? (enabled?, missing? different size?)
local_copy_needed() {
    [ "$LOCAL_COPY_ENABLED" = "true" ] || return 1
    # ignore unencrypted backups, if not allowed
    if backup_blocked "$1"; then return 1; fi
    [ -f "${DEST}/${2}" ] || return 0
    [ "$(stat -c%s "$1" 2>/dev/null)" != "$(stat -c%s "${DEST}/${2}" 2>/dev/null)" ]
}

# free bytes on the filesystem containing $1
free_bytes() {
    local kb
    kb=$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "$kb" =~ ^[0-9]+$ ]] || return 1
    echo $((kb * 1024))
}

# enough room in $DEST for a file of $1 bytes? (unknown free space = proceed)
local_has_space() {
    local size="$1" free
    free=$(free_bytes "$DEST") || {
        bashio::log.warning "Could not determine free space in ${DEST}, copying anyway"
        return 0
    }
    if [ "$free" -lt $((size + LOCAL_FREE_BYTES)) ]; then
        bashio::log.error "Not enough space in ${DEST}: need ${size} + ${LOCAL_FREE_BYTES} margin, have ${free}"
        return 1
    fi
}

# local copy and verification, ie copy new file from $SRC to $DEST
local_copy() {
    [ "$LOCAL_COPY_ENABLED" = "true" ] || return 0

    local f="$1" base="$2" now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# make sure the folder exists
    mkdir -p "$DEST"

    # check sufficient space on local target
    local src_size_pre
    src_size_pre=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if ! local_has_space "$src_size_pre"; then
        fire_event "new_backup_copy_failed" "$(event_payload "$base" "${DEST}/${base}" "$now" "insufficient_space")"
        return 1
    fi

    # copy in the background and wait for it, so a stop request can interrupt even a long copy (see on_stop)
    local tmp="${DEST}/${base}.tmp" copy_ok="true"
    # remember the currently handled file in case copy gets interrupted
    CURRENT_TMP="$tmp"
    # start copying with "&" continue script while operation is ongoing
    cp -f "$f" "$tmp" &
    # remember the current process id of the copy "$!" in case copy gets interrupted
    CP_PID=$!
    # now wait for the copy to complete, then rename the file - and in case of error flag as not ok
    { wait "$CP_PID" && mv -f "$tmp" "${DEST}/${base}"; } || copy_ok="false"
    CP_PID=""
    CURRENT_TMP=""
    if [ "$copy_ok" != "true" ]; then
        # remove leftovers in case copying fails
        rm -f -- "${DEST}/${base}.tmp"
        bashio::log.error "Failed to copy ${base}"
        fire_event "new_backup_copy_failed" "$(event_payload "$base" "${DEST}/${base}" "$now")"
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
        fire_event "new_backup_copy_failed" "$(event_payload "$base" "${DEST}/${base}" "$now" "size_mismatch")"
        return 1
    fi

    bashio::log.info "Copied and verified ${base} (${dest_size} bytes) to ${DEST}/${base}"
    fire_event "new_backup_copied" "$(event_payload "$base" "${DEST}/${base}" "$now")"
    return 0
}

# mirror deletions in local target folder, ie remove any file from $DEST that no longer exists in $SRC
local_sync_deletions() {
    [ "$LOCAL_COPY_ENABLED" = "true" ] || return 0
    [ "$LOCAL_SYNC_DELETIONS" = "true" ] || return 0

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

# create fingerprint of file using size and modification time
file_fingerprint() {
    stat -c '%s:%Y' "$1" 2>/dev/null || echo "missing"
}

# determine encryption state of backup $1: "encrypted", "plain" or "unknown" (unreadable, no flag)
# note: backup.json is stored unencrypted inside the backup tar, tar skips over the large inner archives
backup_encryption() {
    local meta protected
    meta=$(tar -xOf "$1" ./backup.json 2>/dev/null || tar -xOf "$1" backup.json 2>/dev/null) || meta=""
    protected=$(printf '%s' "$meta" | jq -e '.protected == true' 2>/dev/null) || protected=""
    case "$protected" in
        true)  echo "encrypted" ;;
        false) echo "plain" ;;
        *)     echo "unknown" ;;
    esac
}
# true = backup $1 must be left alone, because unencrypted backups are not allowed and it is not (verifiably) encrypted
backup_blocked() {
    [ "$ALLOW_UNENCRYPTED" != "true" ] || return 1
    [ "$(backup_encryption "$1")" != "encrypted" ]
}

# process new file detected in $SRC
process_file() {
    local f="$1"
    # only act on *.tar backup files
    case "$f" in
        *.tar)
            local base
            base=$(basename "$f")

            # policy: leave unencrypted backups alone, unless explicitly allowed
            if backup_blocked "$f"; then
                bashio::log.warning "${base} is not recognised as encrypted: skipping it. Enable backup encryption in Home Assistant, or set allow_unencrypted_backups in the app configuration"
                return 0
            fi

            # nothing to do if file was already handled (eg repeated events, restart)
            if ! local_copy_needed "$f" "$base" && ! ftps_upload_needed "$f" "$base"; then
                bashio::log.debug "${base} already handled, skipping"
                return 0
            fi
            bashio::log.info "Detected new backup: ${base}"
            if [ "$(backup_encryption "$f")" = "plain" ]; then
                bashio::log.warning "${base} is not encrypted: the copies made by this app will contain secrets in plain text"
            fi

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

            # new backup file is stable, what needs to be done?
            if local_copy_needed "$f" "$base"; then
                local_copy "$f" "$base" || true
            fi
            if ftps_upload_needed "$f" "$base"; then
                ftps_upload "$f"
            fi

            ;;
    esac
}

# files modified more recently than this are skipped by resync and handled (latest) next resync
RESYNC_MIN_AGE=60  # seconds
# frequency for resync checks covering eg failed upload, missed event, local copy removed
RESYNC_CHECK_INTERVAL=3600  # seconds / 1 hour as we only handle backups = 24 checks a day

# scan backups in $SRC
# by default only returns 0 (= true) if any backup still lacks a local copy or an upload
# with "sync" as parameter: process every backup, copy and upload required ones, then mirror deletions - always returns 0
scan_backups() {
    local mode="${1:-}" f now mtime base

    now=$(date +%s)
    for f in "${SRC}"/*.tar; do
        # skip the literal "*.tar" response bash leaves when no backups exist
        [ -e "$f" ] || continue
        mtime=$(stat -c%Y "$f" 2>/dev/null || echo "$now")
        # no check for too "young" files possibly still being written: handled by its own close_write event, or a later check
        [ $((now - mtime)) -ge "$RESYNC_MIN_AGE" ] || continue

        if [ "$mode" = "sync" ]; then
            process_file "$f" || true
        else
            base=$(basename "$f")
            if local_copy_needed "$f" "$base" || ftps_upload_needed "$f" "$base"; then
                return 0
            fi
        fi
    done

    if [ "$mode" != "sync" ]; then
        return 1
    fi
    local_sync_deletions || true
    ftps_sync_deletions || true
    ftps_cleanup_state || true
}

# watch for files fully written (close_write) to renamed/moved into place (moved_to) to $SRC and removals (delete, moved_from)
MAX_FAST_FAILURES=10  # number (reset to 0 upon first non-"fast" restart required)
FAST_FAILURE_WINDOW=30  # seconds (restart faster than this counts as "fast")
watch_backups() {
    local fast_failure_count=0
    local start_ts end_ts elapsed next_check remaining fd line event filename rc

    while true; do
        start_ts=$(date +%s)

        # start the watch FIRST: files created while the (possibly long) resync below runs
        # are queued as events and handled afterwards, instead of being missed
        bashio::log.info "Start inotifywait watch on ${SRC}"
        exec {fd}< <(inotifywait -m -e close_write -e moved_to -e delete -e moved_from --format '%e %f' "$SRC")

        # resync in case events were missed while the watch was down
        scan_backups "sync"
        next_check=$(($(date +%s) + RESYNC_CHECK_INTERVAL))

        # handle queued and new events, check regularly whether anything is still not fully handled
        while true; do
            remaining=$((next_check - $(date +%s)))
            if [ "$remaining" -le 0 ]; then
                next_check=$(($(date +%s) + RESYNC_CHECK_INTERVAL))
                if scan_backups; then
                    bashio::log.info "Some backups are not fully handled yet, retrying"
                    scan_backups "sync"
                fi
                continue
            fi

            rc=0
            IFS= read -r -t "$remaining" -u "$fd" line || rc=$?
            if [ "$rc" -eq 0 ]; then
                # line format "EVENT FILENAME": event names contain no spaces, file names might
                event=${line%% *}
                filename=${line#* }
                # only *.tar backups matter, ignore anything else appearing in $SRC
                case "$filename" in
                    *.tar) ;;
                    *) continue ;;
                esac
                # a new or moved-in backup needs processing, a removed one only the deletion sync
                case "$event" in
                    DELETE*|MOVED_FROM*) ;;
                    *) process_file "${SRC}/${filename}" || true ;;
                esac
                local_sync_deletions || true
                ftps_sync_deletions || true
                ftps_cleanup_state || true
            elif [ "$rc" -le 128 ]; then
                break  # end of input: inotifywait exited
            fi
            # rc > 128: read timed out, loop around and check
        done
        exec {fd}<&-

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
            bashio::log.error "Exiting so app is marked as failed rather than retrying forever"
            exit 1
        fi

        sleep 5
    done
}

# warn (only) if backups exist that are not recognised as encrypted
# note: meant to run in the background, so reading every backup.json never delays the start of the watch
warn_unencrypted_backups() {
    local f total=0 unencrypted=0
    for f in "${SRC}"/*.tar; do
        [ -e "$f" ] || continue
        total=$((total + 1))
        if [ "$(backup_encryption "$f")" != "encrypted" ]; then
            unencrypted=$((unencrypted + 1))
        fi
    done

    # nothing to report
    [ "$unencrypted" -gt 0 ] || return 0

    if [ "$ALLOW_UNENCRYPTED" = "true" ]; then
        bashio::log.warning "${unencrypted} of ${total} backups in ${SRC} are not recognised as encrypted: their copies will contain secrets in plain text"
    else
        bashio::log.warning "${unencrypted} of ${total} backups in ${SRC} are not recognised as encrypted: they will not be copied / uploaded"
    fi
}

# let's get started
bashio::log.info "Backup Watcher starting..."
bashio::log.info "Watching ${SRC} for new backup files"
# analyze and warn user, if required, without blocking startup by using "&"
warn_unencrypted_backups &
watch_backups
