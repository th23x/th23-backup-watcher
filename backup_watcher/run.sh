#!/usr/bin/with-contenv bashio

# --- SETUP ---

# fail "loudly" on errors to be able to detect reccuring issues
# note: requires checks eg to not make some FTP connection issue fail the whole script
set -euo pipefail

# basic constants
SRC="/backup"
APP_CONFIG_DIR="/config"
FTPS_DESTINATION_FILE="/data/ftps_destination" # destination the upload records belong to, the records are reset if it changes
FTPS_STATE_DIR="/data/ftps_uploaded" # tracks files uploaded to server, survives restarts as /data is persistent
FTPS_INPROGRESS_FILE="/data/ftps_upload_in_progress" # remote temp files per line, tracking leftovers in case of hard stops midway
SKIPPED_DIR="/tmp/backup_skipped" # backups already reported as skipped, see backup_skipped function
FAILED_DIR="/tmp/backup_upload_failed" # failed uploads: attempts, last reason, next retry, see ftps_upload_failed function
RETRY_MAX_DELAY=86100 # seconds: wait between retries of failed upload grows with each failure, but never beyond (just under) a day
BACKUP_JSON_MAX_BYTES=262144 # backup.json is a few KB, anything larger than 256 KiB is not read (and counts as "unknown")
ENCRYPTION_CACHE_DIR="/tmp/backup_encryption" # remembered results per backup, /tmp is cleared on restart

# handle HA shutdown commands (instead waiting for a hard "kill")
# runs on every exit (stop request, fatal error, normal end): remove the partial copy still in progress
on_exit() {
    # stop any ongoing upload
    pkill -x lftp 2>/dev/null || true
    # stop the inotifywait started by watch_backups
    pkill -x inotifywait 2>/dev/null || true
}
# runs on a stop request from Supervisor / Docker (SIGTERM) or Ctrl-C when testing manually (SIGINT)
on_stop() {
    bashio::log.info "Stop requested, shutting down"
    exit 0  # runs the EXIT trap
}
trap on_stop SIGTERM SIGINT
trap on_exit EXIT

# security: allow unencrypted backups
ALLOW_UNENCRYPTED=$(bashio::config 'allow_unencrypted_backups')
if [ "$ALLOW_UNENCRYPTED" = "true" ]; then
    bashio::log.warning "allow_unencrypted_backups is on: Unencrypted backups (with secrets in plain text) will be uploaded!"
else
    bashio::log.info "Only encrypted backups will be uploaded"
fi

# FTPs upload configuration
FTPS_HOST=$(bashio::config 'ftps_host')
FTPS_PORT=$(bashio::config 'ftps_port')
FTPS_IMPLICIT=$(bashio::config 'ftps_implicit')
FTPS_USER=$(bashio::config 'ftps_user')
FTPS_PASSWORD=$(bashio::config 'ftps_password')
FTPS_REMOTE_DIR=$(bashio::config 'ftps_remote_dir')
FTPS_VERIFY_CERT=$(bashio::config 'ftps_verify_cert')
FTPS_CA_FILE=$(bashio::config 'ftps_ca_file')
# unset optional value comes back as "null", convert to empty string instead
if [ "$FTPS_CA_FILE" = "null" ]; then FTPS_CA_FILE=""; fi
# limit file name to inside the app's private configuration folder (schema forbids any "/")
if [ -n "$FTPS_CA_FILE" ]; then FTPS_CA_FILE="${APP_CONFIG_DIR}/${FTPS_CA_FILE}"; fi
FTPS_CHECK_HOSTNAME=$(bashio::config 'ftps_check_hostname')
FTPS_SYNC_DELETIONS=$(bashio::config 'ftps_sync_deletions')
FTPS_ATOMIC_UPLOAD=$(bashio::config 'ftps_atomic_upload')
# only an explicit false turns it off (unset comes back as "null")
if [ "$FTPS_ATOMIC_UPLOAD" != "false" ]; then FTPS_ATOMIC_UPLOAD="true"; fi

# validate configuration: without a usable FTPs upload app won't work, so any problem is fatal
CONFIG_ERRORS=()

# prevent control characters in text options
# note: values end up in the lftp script line by line, so a line break would start a new lftp command (not acceptable)
# note: the schema already rejects control characters in host, user, remote dir and CA file, the password can only be checked here
bad_fields=()
[[ "$FTPS_HOST" =~ [[:cntrl:]] ]] && bad_fields+=("ftps_host") || true
[[ "$FTPS_USER" =~ [[:cntrl:]] ]] && bad_fields+=("ftps_user") || true
[[ "$FTPS_PASSWORD" =~ [[:cntrl:]] ]] && bad_fields+=("ftps_password") || true
[[ "$FTPS_REMOTE_DIR" =~ [[:cntrl:]] ]] && bad_fields+=("ftps_remote_dir") || true
[[ "$FTPS_CA_FILE" =~ [[:cntrl:]] ]] && bad_fields+=("ftps_ca_file") || true
if [ "${#bad_fields[@]}" -gt 0 ]; then
    bad_list=$(IFS=,; echo "${bad_fields[*]}")
    bashio::log.error "Invalid configuration, control characters (eg a line break) found in: ${bad_list//,/, }"
    bashio::log.error "Exiting: fix the configuration and start the app again"
    # exit code 0: a restart can not fix a configuration error, so Supervisor's watchdog (user setting) must not restart in a loop
    exit 0
fi

# ensure proper configuration
[ -n "$FTPS_HOST" ] || CONFIG_ERRORS+=("ftps_host is empty")
[ -n "$FTPS_USER" ] || CONFIG_ERRORS+=("ftps_user is empty")
[ -n "$FTPS_PASSWORD" ] || CONFIG_ERRORS+=("ftps_password is empty")
[[ "$FTPS_REMOTE_DIR" != /* ]] || CONFIG_ERRORS+=("ftps_remote_dir must not start with /")
if [ "$FTPS_VERIFY_CERT" = "true" ]; then
    if [ -n "$FTPS_CA_FILE" ]; then
        # resolve symlinks: the real file must be a regular file inside the app's configuration folder
        ca_real=$(realpath "$FTPS_CA_FILE" 2>/dev/null || true)
        if [ -z "$ca_real" ] || [ ! -e "$ca_real" ]; then
            CONFIG_ERRORS+=("ftps_ca_file '${FTPS_CA_FILE}' not found")
        elif [[ "$ca_real" != "${APP_CONFIG_DIR}"/* ]]; then
            CONFIG_ERRORS+=("ftps_ca_file '${FTPS_CA_FILE}' resolves to a file outside the app's configuration folder (symlink)")
        elif [ ! -f "$ca_real" ] || [ ! -r "$ca_real" ] || ! grep -q 'BEGIN CERTIFICATE' "$ca_real"; then
            CONFIG_ERRORS+=("ftps_ca_file '${FTPS_CA_FILE}' is not a readable PEM certificate file")
        else
            FTPS_CA_FILE="$ca_real"   # let lftp read exactly the file that was checked
        fi
    fi
    if [ "$FTPS_CHECK_HOSTNAME" != "true" ] && [ -z "$FTPS_CA_FILE" ]; then
        CONFIG_ERRORS+=("ftps_check_hostname can only be turned off together with a ftps_ca_file, otherwise any publicly trusted certificate would be accepted")
    fi
fi
if [ "${#CONFIG_ERRORS[@]}" -gt 0 ]; then
    for err in "${CONFIG_ERRORS[@]}"; do
        bashio::log.error "Invalid configuration: ${err}"
    done
    bashio::log.error "Exiting: fix the configuration and start the app again"
    # exit code 0: a restart can not fix a configuration error, so Supervisor's watchdog (user setting) must not restart in a loop
    exit 0
fi

# implicit FTPs does not work on port 21 (explicit FTPs), recommend using the standard port 990 instead
if [ "$FTPS_IMPLICIT" = "true" ] && [ "$FTPS_PORT" = "21" ]; then
    bashio::log.warning "ftps_implicit is on, but port 21 is the explicit FTPs port, which might not work properly. Change configuration to use port 990 instead, the standard for implicit FTPs"
fi

# log status of FTPs upload
bashio::log.info "FTPs upload to ${FTPS_USER}@${FTPS_HOST}:${FTPS_PORT}/${FTPS_REMOTE_DIR} (implicit=${FTPS_IMPLICIT}, verify_cert=${FTPS_VERIFY_CERT}, check_hostname=${FTPS_CHECK_HOSTNAME}, ca_file=${FTPS_CA_FILE:-system}, sync_deletions=${FTPS_SYNC_DELETIONS})"
if [ "$FTPS_VERIFY_CERT" != "true" ]; then
    bashio::log.warning "ftps_verify_cert is off: password and backups are exposed to man-in-the-middle attacks. Use ftps_ca_file instead"
    [ -z "$FTPS_CA_FILE" ] || bashio::log.warning "ftps_ca_file is ignored while ftps_verify_cert is off"
elif [ "$FTPS_CHECK_HOSTNAME" != "true" ]; then
    bashio::log.warning "ftps_check_hostname is off: the server name is not checked, only the certificate in ftps_ca_file is trusted. It must be the server's own certificate (or a CA you alone control)"
fi
if [ "$FTPS_ATOMIC_UPLOAD" != "true" ]; then
    bashio::log.warning "ftps_atomic_upload is off: backups are uploaded straight to their final name, so a failed upload can leave an incomplete file on the server until the next attempt replaces it"
fi

# ensure required directories exist
mkdir -p "$FTPS_STATE_DIR" # persistent own uploads states
mkdir -p "$ENCRYPTION_CACHE_DIR" # temporary cache directory for encryption status
mkdir -p "$SKIPPED_DIR" # skipped backup files
mkdir -p "$FAILED_DIR" # failed uploads, for back-off

# the upload records only make sense for the server and folder they were made for
# if the destination changed, forget them, so existing backups are uploaded to the new place
# note: nothing is deleted on the old destination
# note: other settings like port, password, etc are not part of the destination, a change there is usually still the same server
check_destination() {
    local dir="$FTPS_REMOTE_DIR" destination previous s records=0
    while [[ "$dir" == */ ]]; do dir=${dir%/}; done
    destination="${FTPS_USER}@${FTPS_HOST,,}/${dir}"
    # no record yet (first start, or update from an older version): just remember it, the existing records stay
    if [ -f "$FTPS_DESTINATION_FILE" ]; then
        previous=$(head -n 1 "$FTPS_DESTINATION_FILE")
        if [ "$previous" != "$destination" ]; then
            for s in "$FTPS_STATE_DIR"/*; do
                [ -f "$s" ] || continue
                rm -f -- "$s" && records=$((records + 1))
            done
            # temp files of interrupted uploads belong to the old destination as well
            rm -f -- "$FTPS_INPROGRESS_FILE"
            bashio::log.warning "FTPs destination changed (${previous} -> ${destination}): forgot ${records} upload record(s), existing backups are uploaded again. The old destination is not touched"
        fi
    fi
    printf '%s\n' "$destination" > "$FTPS_DESTINATION_FILE" 2>/dev/null || true
}
check_destination

# remember remote server capabilities
FTPS_AVBL_SUPPORTED="unknown" # check free space
FTPS_SIZE_SUPPORTED="unknown" # check file size

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

# is the server reachable at all (TCP connect to host and port, 5 s at most), otherwise sets FTPS_DOWN, which ends the current resync early (see scan_backups)
# note: only used AFTER an lftp command failed, to avoid more slow attempts during an outage
# note: says nothing about TLS or login, lftp reports those itself and quickly
FTPS_DOWN="false"
ftps_reachable() {
    if timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${FTPS_HOST//[\[\]]/}" "$FTPS_PORT" 2>/dev/null; then
        FTPS_DOWN="false"
    else
        FTPS_DOWN="true"
        return 1
    fi
}

# did the server refuse our login (wrong user or password)? Sets FTPS_AUTH_FAILED, which ends the current round like FTPS_DOWN does:
# a wrong password then costs one login per round instead of three per backup (fail2ban on the server could lock the address out)
# note: only used on the output of a FAILED lftp command; lftp words it "Login failed: 530 ..." for every command
FTPS_AUTH_FAILED="false"
ftps_note_auth_failure() {
    if printf '%s' "$1" | grep -Eqi 'Login failed: [45][0-9]{2}'; then
        if [ "$FTPS_AUTH_FAILED" != "true" ]; then
            FTPS_AUTH_FAILED="true"
            bashio::log.warning "FTPs login refused: check ftps_user and ftps_password. Further attempts in this round are skipped"
        fi
        return 0
    fi
    return 1
}

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
# important: minimum required is TLS 1.2: lftp has no "min-protocol" setting, only ssl:priority
# note: "cd ." forces login first, so refusal ends the script instead of "mkdir -p -f" hiding it and "cd ..." logging in a second time
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
set ssl:priority "NORMAL:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1"
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
cd .
mkdir -p -f $(lftp_quote "$FTPS_REMOTE_DIR")
cd $(lftp_quote "$FTPS_REMOTE_DIR")
EOF
}

# run lftp commands with standard prelude
# note: script executes via stdin, so credentials never show up in the process list
ftps_run() {
    lftp -f /dev/stdin <<<"$(ftps_prelude)"$'\n'"$1"
}

# last 3 lines of lftp output $1 for the log, with the password masked
# note: lftp is not expected to print it, this is only a safeguard. The pattern is quoted, so characters like * ? [ in the password are matched literally
ftps_log_tail() {
    local s="$1" q
    q=$(lftp_quote "$FTPS_PASSWORD"); q=${q:1:-1}   # the form written into the lftp script (backslash and double quote escaped)
    s=${s//"$FTPS_PASSWORD"/"***"}
    s=${s//"$q"/"***"}
    printf '%s' "$s" | tail -n 3
}

# ftp error classification; especially identify remote disk space constraints
# note: only matches FTP replies, i.e. starting with reply code or "Access failed: " or "<--- " prefix, NOT number or word elsewhere in text (user name, file name, byte counts, our own messages)
ftps_classify_error() {
    # 452 (insufficient storage) and 552 (exceeded storage allocation) say it by themselves
    if printf '%s' "$1" | grep -Eq '(^|Access failed: |<--- )(452|552)([^0-9]|$)'; then
        echo "insufficient_space"
    # servers that answer a full disk with a generic code (450, 451, 550) usually say so in the reply text
    # note: the phrase must start the reply text (or follow a short lead-in like "file: " or "Could not write file. "), and a path never counts:
    # the lead-in may not contain a "/" and the phrase may not be followed by one, so a server that echoes a folder called "no space" does not match
    elif printf '%s' "$1" | grep -Eqi '(^|Access failed: |<--- )(45[01]|550)[ -]+([^:(/]*[:.] +)?(disk full|no space|not enough (disk )?space|insufficient (storage|space)|quota exceeded)([^/]|$)'; then
        echo "insufficient_space"
    else
        echo "upload_error"
    fi
}

# does lftp output $1 contain a 500-504 reply, ie the server answered the command itself with "unknown / not implemented"?
# note: only to be used on the output of a FAILED command. Login, cd and transfer problems use other codes (530, 550, 4xx) or no reply at all and must never be mistaken for a missing command
ftps_command_unsupported() {
    printf '%s' "$1" | grep -Eq '(^|[^0-9])50[0-4]([^0-9]|$)'
}

# check free space on remote server
# return "1" only if the server reports less free space than needed
# return "2" if the server is not reachable or login refused (text in FTPS_ERROR, uploading would only wait for the same timeouts again)
# note: a server not supporting the AVBL command is remembered, connection or login problems do not change that
ftps_has_space() {
    [ "$FTPS_AVBL_SUPPORTED" != "no" ] || return 0

    local size="$1" out free
    # not reachable or login failed: no statement about AVBL support possible
    if ! out=$(ftps_run "quote AVBL" 2>&1); then
        if ftps_note_auth_failure "$out"; then
            # login refused: report it right away, the upload would only fail the same way again
            FTPS_ERROR="$out"
            return 2
        elif ftps_command_unsupported "$out"; then
            # avbl unsupported: a 5xx reply to the command itself means the server is reachable but lacks AVBL
            FTPS_AVBL_SUPPORTED="no"
            bashio::log.info "FTPs: server does not report free space"
        elif ! ftps_reachable; then
            # server down: report it right away; any other problem (eg login) is left to the upload, which reports it quickly
            FTPS_ERROR="server not reachable: ${out}"
            return 2
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

# failure record of backup $2 (file $1): prints "attempts next_epoch reason"; fails if there is none for this exact file (same size and modification time)
ftps_failure_record() {
    local m fp attempts next reason
    m=$(cat "${FAILED_DIR}/${2}" 2>/dev/null) || return 1
    read -r fp attempts next reason <<<"$m" || return 1
    [ "$fp" = "$(file_fingerprint "$1")" ] || return 1
    echo "${attempts} ${next} ${reason}"
}

# check if retry of backup $2 (file $1) is due yet; it failed before and the wait has not passed
ftps_backed_off() {
    local rec attempts next reason
    rec=$(ftps_failure_record "$1" "$2") || return 1
    read -r attempts next reason <<<"$rec"
    [ "$(date +%s)" -lt "$next" ]
}

# remember and report the failed upload of $2 (file $1, fingerprint $3) with reason $4, error text in FTPS_ERROR
# - back-off: each attempt costs several logins and a persistent problem (eg wrong password) does not fix itself
#   so the retry is only due at the 1st, 2nd, 4th, 8th ... hourly check after the failure
#   (5 min less make sure the attempt's own duration does not push it to the next check)
# - the failure event only fires for the first failure of a file and when the reason changes, not on every retry:
#   an automation sending a notification would otherwise notify hourly. A later success fires new_backup_uploaded
ftps_upload_failed() {
    local f="$1" base="$2" fp="$3" reason="$4" now now_epoch rec attempts=0 next last_reason="" n delay detail=""
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    now_epoch=$(date +%s)
    if rec=$(ftps_failure_record "$f" "$base"); then
        read -r attempts next last_reason <<<"$rec"
    fi
    attempts=$((attempts + 1))
    n=$((attempts - 1))
    if [ "$n" -gt 5 ]; then n=5; fi
    delay=$(( (1 << n) * RESYNC_CHECK_INTERVAL - 300 ))
    if [ "$delay" -gt "$RETRY_MAX_DELAY" ]; then delay="$RETRY_MAX_DELAY"; fi

    if [ -n "$FTPS_ERROR" ]; then detail=": $(ftps_log_tail "$FTPS_ERROR")"; fi
    bashio::log.error "FTPs: failed to upload ${base} (${reason})${detail} - attempt ${attempts}, next retry in about $(( (delay + 300) / 3600 )) h"
    if [ "$reason" != "$last_reason" ]; then
        fire_event "new_backup_upload_failed" "$(event_payload "$base" "${FTPS_REMOTE_DIR:+${FTPS_REMOTE_DIR}/}${base}" "$now" "$reason")"
    fi
    printf '%s %s %s %s\n' "$fp" "$attempts" "$((now_epoch + delay))" "$reason" > "${FAILED_DIR}/${base}" 2>/dev/null || true
}

# the server just accepted an upload, so it is healthy: other failed backups can be retried on the next check as well
ftps_release_backoff() {
    local rec fp attempts next reason
    for rec in "${FAILED_DIR}"/*; do
        [ -f "$rec" ] || continue
        read -r fp attempts next reason < "$rec" || continue
        printf '%s %s 0 %s\n' "$fp" "$attempts" "$reason" > "$rec" 2>/dev/null || true
    done
}

# is an FTPs upload of file $1 (basename $2) required? (enabled?, never uploaded? changed since?)
# note: state file holds the fingerprint of the uploaded file
# important: files remotely deleted manually will NOT be re-uploaded
ftps_upload_needed() {
    # skipped and reported already (see backup_skipped function): nothing to do until the file changes
    if backup_skip_reported "$1" "$2"; then return 1; fi
	# failed before and the retry is not due yet (see ftps_upload_failed)
	if ftps_backed_off "$1" "$2"; then return 1; fi
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
    local f="$1"
    local base now size fp reason space_rc=0
    base=$(basename "$f")
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    fp=$(file_fingerprint "$f")

    # check sufficient space on remote target
    ftps_has_space "$size" || space_rc=$?
    if [ "$space_rc" -eq 1 ]; then
        FTPS_ERROR=""
        ftps_upload_failed "$f" "$base" "$fp" "insufficient_space"
        return 1
    fi

    # upload via temp name and rename, so the final name only ever points to a complete file
    # note: not inside $(...), as ftps_put_atomic hands the error text back in FTPS_ERROR
    # note: skipped if the space check found the server not reachable (space_rc 2), its error text is reported below
    if [ "$space_rc" -eq 0 ] && ftps_put_atomic "$f" "$base"; then
        bashio::log.info "FTPs: uploaded ${base}"
        FTPS_AUTH_FAILED="false"
        fire_event "new_backup_uploaded" "$(event_payload "$base" "${FTPS_REMOTE_DIR:+${FTPS_REMOTE_DIR}/}${base}" "$now")"
        # keep persistent track of the upload: state file holds fingerprint of the uploaded file
        echo "$fp" > "${FTPS_STATE_DIR}/${base}" 2>/dev/null || true
        # healthy again: forget earlier failures of this file, the other failed backups may retry at the next check
        rm -f -- "${FAILED_DIR}/${base}"
        ftps_release_backoff
    else
        # document reason for upload failure
        reason=$(ftps_classify_error "$FTPS_ERROR")
        ftps_upload_failed "$f" "$base" "$fp" "$reason"
    fi
}

# remove our own leftover temp file $1 (a *.tar.tmp name) from the server (current remote dir)
# note: lists first, so a file that is already gone counts as done; fails only if the server could not be reached or refused
ftps_remove_remote_tmp() {
    local name="$1" listing

    [[ "$name" == *.tar.tmp && "$name" != */* ]] || return 0 # never touch anything but our own temp names
    ftps_reachable || return 1 # server down: nothing can be removed now, the marker stays and the next check retries

    if ! listing=$(ftps_run "cls -1" 2>&1); then
        ftps_note_auth_failure "$listing" || true
        return 1
    fi
    if printf '%s\n' "$listing" | grep -Fxq -- "$name"; then
        ftps_run "rm -f $(lftp_quote "$name")" >/dev/null 2>&1 || return 1
    fi
}

# marker file: one name per line, add / remove a single remote temp file name $1
ftps_marker_add() {
    grep -Fxq -- "$1" "$FTPS_INPROGRESS_FILE" 2>/dev/null || printf '%s\n' "$1" >> "$FTPS_INPROGRESS_FILE" 2>/dev/null || true
}
ftps_marker_remove() {
    local rest
    [ -f "$FTPS_INPROGRESS_FILE" ] || return 0
    rest=$(grep -Fxv -- "$1" "$FTPS_INPROGRESS_FILE" 2>/dev/null) || true
    if [ -n "$rest" ]; then
        { printf '%s\n' "$rest" > "${FTPS_INPROGRESS_FILE}.new" && mv -f "${FTPS_INPROGRESS_FILE}.new" "$FTPS_INPROGRESS_FILE"; } 2>/dev/null || true
    else
        rm -f -- "$FTPS_INPROGRESS_FILE" 2>/dev/null || true
    fi
}

# after a failed upload: remove the remote temp file $1 and forget the marker, the marker stays if that did not work (retried at next start)
# note: only for atomic uploads; without them there is no temp file, and a final file is never deleted here (it might be the intact previous copy)
ftps_drop_tmp() {
    [ "$FTPS_ATOMIC_UPLOAD" = "true" ] || return 0
    if ftps_remove_remote_tmp "$1"; then
        ftps_marker_remove "$1"
    fi
}

# at start (and at every hourly check): remove the remote temp files of uploads that a stop cut off
# note: names remembered in $FTPS_INPROGRESS_FILE
ftps_cleanup_interrupted() {
    [ -s "$FTPS_INPROGRESS_FILE" ] || return 0
    # login refused earlier in this round: do not try again
    [ "$FTPS_AUTH_FAILED" != "true" ] || return 0
    local names name
    # one check for the server instead of a timeout per name
    if ! ftps_reachable; then
        bashio::log.warning "FTPs: server not reachable, leftovers of interrupted uploads are removed later"
        return 0
    fi
    mapfile -t names < "$FTPS_INPROGRESS_FILE"
    for name in "${names[@]}"; do
        [ -n "$name" ] || continue
        if ftps_remove_remote_tmp "$name"; then
            bashio::log.info "FTPs: cleaned up after an interrupted upload (${name})"
            ftps_marker_remove "$name"
        else
            bashio::log.warning "FTPs: could not remove ${name} left by an interrupted upload, will retry"
            [ "$FTPS_AUTH_FAILED" != "true" ] || break   # login refused: the other names would fail the same way
        fi
    done
}

# upload file $1 as $2: first under a temp name, so the final name only ever points to a complete file
# (with ftps_atomic_upload off: straight to the final name, for servers that do not allow renaming)
# note: on failure the error text is left in FTPS_ERROR for the caller to classify and log
FTPS_ERROR=""
ftps_put_atomic() {
    local f="$1" base="$2" target="$2" old="$2.old" out listing local_size outfile pid attempt=1 size_rc=1 put_script merged_size rc=0
    FTPS_ERROR=""

    if [ "$FTPS_ATOMIC_UPLOAD" = "true" ]; then
        target="${base}.tmp"
        # remember the temp name until it is gone from the server, see ftps_cleanup_interrupted
        ftps_marker_add "$target"
    fi

    # note: lftp runs in the background and the script waits for it: bash only runs a trap after a foreground command has finished,
    # but "wait" is interrupted at once by a stop request (SIGTERM); not inside $(...), the trap would be deferred again
    if ! outfile=$(mktemp /tmp/lftp_out.XXXXXX); then
        FTPS_ERROR="cannot create temp file for the upload output"
        ftps_drop_tmp "$target"
        return 1
    fi
    # once the server is known to report sizes, ask for the size in the same session: one login less. The separate query below stays as the fallback
    put_script="put $(lftp_quote "$f") -o $(lftp_quote "$target")"
    if [ "$FTPS_SIZE_SUPPORTED" = "yes" ]; then
        put_script+=$'\n'"quote SIZE $(lftp_quote "$target")"
    fi
    lftp -f /dev/stdin <<<"$(ftps_prelude)"$'\n'"$put_script" >"$outfile" 2>&1 &
    pid=$!
    wait "$pid" || rc=$?
	out=$(cat "$outfile" 2>/dev/null) || true
    rm -f -- "$outfile"
    if [ "$rc" -ne 0 ]; then
        FTPS_ERROR="$out"
        if ftps_note_auth_failure "$out"; then
            # login refused: nothing was created on the server, so there is nothing to remove (and no further login to waste)
            ftps_marker_remove "$target"
        else
            ftps_drop_tmp "$target"
        fi
        return 1
    fi

    # verify size, unless the server is known not to report it
    # note: "not supported" is only concluded from the server's own answer. A connection or other problem is retried, and if it persists the upload fails: a file that could not be verified is never published
    if [ "$FTPS_SIZE_SUPPORTED" != "no" ]; then
        local_size=$(stat -c%s "$f" 2>/dev/null || echo -1)
        # size already answered in the put session? (a failing SIZE there fails the whole session, so a good put with a reply means both worked)
        if [ "$FTPS_SIZE_SUPPORTED" = "yes" ]; then
            merged_size=$(printf '%s\n' "$out" | grep -Eo '213 [0-9]+' | tail -1 | awk '{print $2}')
            if [[ "$merged_size" =~ ^[0-9]+$ ]]; then
                FTPS_REMOTE_SIZE="$merged_size"
                size_rc=0
            fi
        fi
        while [ "$size_rc" -ne 0 ]; do
            size_rc=0
            ftps_remote_size "$target" || size_rc=$?
            # 0 = size known, 2 = server has no SIZE command: nothing to retry
            if [ "$size_rc" -ne 1 ] || [ "$attempt" -ge 3 ]; then break; fi
            ftps_reachable || break # server down: retrying would only wait for the same timeouts
            attempt=$((attempt + 1))
            # note: wait instead of a foreground sleep, so a stop request (SIGTERM) is handled at once
            sleep 5 & wait $! || true
        done
        case "$size_rc" in
            0)
                FTPS_SIZE_SUPPORTED="yes"
                FTPS_ERROR=""
                if [ "$FTPS_REMOTE_SIZE" != "$local_size" ]; then
                    FTPS_ERROR="size mismatch: local=${local_size} remote=${FTPS_REMOTE_SIZE}"
                    ftps_drop_tmp "$target"
                    return 1
                fi
                ;;
            2)
                FTPS_SIZE_SUPPORTED="no"
                FTPS_ERROR=""
                bashio::log.info "FTPs: server does not report file sizes, uploads are not verified"
                ;;
            *)
                FTPS_ERROR="could not verify the size of the uploaded file after ${attempt} attempts: ${FTPS_ERROR}"
                ftps_drop_tmp "$target"
                return 1
                ;;
        esac
    fi

    # direct upload: already under the final name
    [ "$FTPS_ATOMIC_UPLOAD" = "true" ] || return 0

    # publish: plain rename first
    if ! out=$(ftps_run "mv $(lftp_quote "$target") $(lftp_quote "$base")" 2>&1); then
        # only if the reply says the target already exists: move the previous version aside, publish, then drop it
        # note: the previous copy is never deleted before the new one is in place, and is put back if publishing fails
        if printf '%s' "$out" | grep -Eqi '(^|Access failed: |<--- )[45][0-9]{2}[ -][^(]*(exists|already|overwrit)'; then
            if out=$(ftps_run "rm -f $(lftp_quote "$old")"$'\n'"mv $(lftp_quote "$base") $(lftp_quote "$old")"$'\n'"mv $(lftp_quote "$target") $(lftp_quote "$base")" 2>&1); then
                ftps_run "rm -f $(lftp_quote "$old")" >/dev/null 2>&1 || true
            else
                # put the previous version back, but only if it was moved aside and the final name is empty
                if listing=$(ftps_run "cls -1" 2>/dev/null) \
                    && printf '%s\n' "$listing" | grep -Fxq -- "$old" \
                    && ! printf '%s\n' "$listing" | grep -Fxq -- "$base"; then
                    ftps_run "mv $(lftp_quote "$old") $(lftp_quote "$base")" >/dev/null 2>&1 || true
                fi
                FTPS_ERROR="$out"
                ftps_drop_tmp "$target"
                return 1
            fi
        else
            FTPS_ERROR="$out"
            ftps_drop_tmp "$target"
            return 1
        fi
    fi
    ftps_marker_remove "$target"
}

# size of remote file $1 in bytes (current remote dir), result in FTPS_REMOTE_SIZE
# returns 0 = size known, 2 = server does not know the SIZE command, 1 = any other problem (connection, login, unexpected reply), which says nothing about SIZE support
# note: the error text of a failed query is left in FTPS_ERROR, so call this directly and not inside $(...)
FTPS_REMOTE_SIZE=""
ftps_remote_size() {
    local out size
    FTPS_REMOTE_SIZE=""
    if ! out=$(ftps_run "quote SIZE $(lftp_quote "$1")" 2>&1); then
        if ftps_command_unsupported "$out"; then return 2; fi
        FTPS_ERROR="$out"
        return 1
    fi
    size=$(printf '%s\n' "$out" | grep -Eo '213 [0-9]+' | tail -1 | awk '{print $2}')
    if ! [[ "$size" =~ ^[0-9]+$ ]]; then
        FTPS_ERROR="unexpected reply to SIZE: ${out}"
        return 1
    fi
    FTPS_REMOTE_SIZE="$size"
}

# mirror deletions on FTPs server, ie remove files this app uploaded (recorded in $FTPS_STATE_DIR) that no longer exist in $SRC
# note: all pending deletions share a single connection, without any pending deletion no connection is made
# note: with "quiet" as parameter (hourly check) the "no backups" notice is only logged at debug level, to not repeat it every hour
ftps_sync_deletions() {
    [ "$FTPS_SYNC_DELETIONS" = "true" ] || return 0
    # login refused earlier in this round: do not try again
    [ "$FTPS_AUTH_FAILED" != "true" ] || return 0

    # ensure sync does not delete all backup uploads, if source does not exist or is (temporarily) not available
    if ! source_without_backups; then
        [ "${1:-}" = "quiet" ] || bashio::log.warning "No backups in ${SRC}, skipping deletion sync"
        return 0
    fi

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
    # note: on server down: skip, as it would cost time(out) and fail anyhow
    if ! ftps_reachable || ! listing=$(ftps_run "cls -1" 2>&1); then
        ftps_note_auth_failure "${listing:-}" || true
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
        bashio::log.warning "FTPs: failed to delete ${#present[@]} file(s), will retry on next sync: $(ftps_log_tail "$out")"
    fi
}

# remove upload state files of backups that no longer exist in $SRC (local only, no network)
# note: with deletion sync enabled, ftps_sync_deletions already handles this
ftps_cleanup_state() {
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

# encryption: determine state of backup $1: "encrypted", "plain" or "unknown" (unreadable, invalid, no or non-boolean flag)
# note: results are cached on disk per file (size and modification time), as this runs in subshells and in a background job
backup_encryption() {
    local f="$1" fp key cached meta state tmp
    fp=$(file_fingerprint "$f")   # taken before reading, so a file changing meanwhile is never cached under its new fingerprint
    key="${ENCRYPTION_CACHE_DIR}/$(printf '%s' "$f" | md5sum | cut -d' ' -f1)"

    # cache hit: file unchanged since it was read
    if [ "$fp" != "missing" ] && cached=$(cat "$key" 2>/dev/null) && [ "${cached%% *}" = "$fp" ]; then
        echo "${cached#* }"
        return 0
    fi

    # backup.json is stored unencrypted inside the backup tar, tar skips over the large inner archives
    # read at most $BACKUP_JSON_MAX_BYTES: head closing the pipe early ends tar with SIGPIPE, which is fine (a truncated file is invalid JSON, so "unknown")
    meta=$({ tar -xOf "$f" ./backup.json 2>/dev/null || tar -xOf "$f" backup.json 2>/dev/null || true; } | head -c "$BACKUP_JSON_MAX_BYTES")
    # strict: only a JSON boolean true is "encrypted", only false is "plain", everything else (also "true", 1, a missing flag, several documents) is "unknown"
    state=$(printf '%s' "$meta" | jq -r 'if .protected == true then "encrypted" elif .protected == false then "plain" else "unknown" end' 2>/dev/null) || state=""
    case "$state" in
        encrypted|plain) ;;
        *) echo "unknown"; return 0 ;;   # not cached, eg a backup still being written
    esac

    # remember result: every writer gets its own temp file and renames it, so parallel runs never touch each other's file
    # note: even failing to cache is harmless, the next run just reads the backup again
    if [ "$fp" != "missing" ]; then
        if tmp=$(mktemp "${key}.XXXXXX" 2>/dev/null); then
            { printf '%s %s\n' "$fp" "$state" > "$tmp" && mv -f "$tmp" "$key"; } 2>/dev/null || rm -f -- "$tmp"
        fi
    fi
    echo "$state"
}

# encryption: was backup $1 (basename $2) already skipped and reported in its current form (same size and modification time)?
backup_skip_reported() {
    local m
    m=$(cat "${SKIPPED_DIR}/${2}" 2>/dev/null) || return 1
    [ "${m%% *}" = "$(file_fingerprint "$1")" ]
}

# encryption: report backup left alone: $1 file, $2 basename, $3 reason (not_encrypted | unreadable), $4 fingerprint
# note: issue a warning in the log plus an event only once per file state: remembered in $SKIPPED_DIR, so repeated events and resyncs stay quiet until the file changes - "memory" is kept in /tmp, so it ends with a restart, which is also when a changed allow_unencrypted_backups takes effect
backup_skipped() {
	local f="$1" base="$2" reason="$3" fp="$4" now level="warning"
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # during the startup resync the summary of warn_unencrypted_backups already warned, the per-file lines then only add the names: info
    if [ "$STARTUP_SYNC" = "true" ]; then level="info"; fi
    if [ "$reason" = "not_encrypted" ]; then
        bashio::log.${level} "${base} is not encrypted: skipping it. Enable backup encryption in Home Assistant, or set allow_unencrypted_backups in the app configuration"
    else
        bashio::log.${level} "${base} could not be read as a Home Assistant backup (no valid backup.json found): skipping it"
    fi
    fire_event "new_backup_skipped" "$(event_payload "$base" "$f" "$now" "$reason")"
    printf '%s %s\n' "$fp" "$reason" > "${SKIPPED_DIR}/${base}" 2>/dev/null || true
}

# process new file detected in $SRC
process_file() {
    local f="$1"
    # only act on *.tar backup files
    case "$f" in
        *.tar)
            local base
            base=$(basename "$f")

            # nothing to do if file was already handled (eg repeated events, restart), or was skipped and reported in its current form
            if ! ftps_upload_needed "$f" "$base"; then
                return 0
            fi
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

            # policy: leave unencrypted backups alone, unless explicitly allowed
            # note: checked only now, a backup still being written has no readable backup.json yet
            local fp enc reason age
            fp=$(file_fingerprint "$f")
            enc=$(backup_encryption "$f")
            if [ "$ALLOW_UNENCRYPTED" != "true" ] && [ "$enc" != "encrypted" ]; then
                if [ "$enc" = "plain" ]; then
                    reason="not_encrypted"
                else
                    reason="unreadable"
                    # a young file might just be slow to finish: no verdict yet, the next event or resync checks again
                    age=$(( $(date +%s) - $(stat -c%Y "$f" 2>/dev/null || date +%s) ))
                    if [ "$age" -lt "$RESYNC_MIN_AGE" ]; then
                        bashio::log.info "${base} has no readable backup.json yet, will check again later"
                        return 0
                    fi
                fi
                backup_skipped "$f" "$base" "$reason" "$fp"
                return 0
            fi
            if [ "$enc" = "plain" ]; then
                bashio::log.warning "${base} is not encrypted: the uploads made by this app will contain secrets in plain text"
            fi

            # new backup file is stable and allowed, what needs to be done?
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

    FTPS_DOWN="false" # set again by the first probe that finds the server down during this pass

    now=$(date +%s)
    for f in "${SRC}"/*.tar; do
        # skip the literal "*.tar" response bash leaves when no backups exist
        [ -e "$f" ] || continue
        mtime=$(stat -c%Y "$f" 2>/dev/null || echo "$now")
        # no check for too "young" files possibly still being written: handled by its own close_write event, or a later check
        [ $((now - mtime)) -ge "$RESYNC_MIN_AGE" ] || continue

        if [ "$mode" = "sync" ]; then
            # login already refused in this round (for example by the cleanup before): the next round tries again
            [ "$FTPS_AUTH_FAILED" != "true" ] || break
            process_file "$f" || true
            # server down: the other backups would only run into the same timeouts, the next check retries them
            if [ "$FTPS_DOWN" = "true" ]; then
                bashio::log.warning "FTPs server not reachable: remaining uploads wait for the next check"
                break
            fi
            # login refused: every other backup would fail the same way
            [ "$FTPS_AUTH_FAILED" != "true" ] || break
        else
            base=$(basename "$f")
            if ftps_upload_needed "$f" "$base"; then
                return 0
            fi
        fi
    done

    if [ "$mode" != "sync" ]; then
        return 1
    fi
    ftps_sync_deletions || true
    ftps_cleanup_state || true
}

# watch for files fully written (close_write) to renamed/moved into place (moved_to) to $SRC and removals (delete, moved_from)
MAX_FAST_FAILURES=10  # number (reset to 0 upon first non-"fast" restart required)
FAST_FAILURE_WINDOW=30  # seconds (restart faster than this counts as "fast")
STARTUP_SYNC="true" # until the first resync after start is done
watch_backups() {
    local fast_failure_count=0
    local start_ts end_ts elapsed next_check remaining fd line event filename rc

    while true; do
        start_ts=$(date +%s)

        # start the watch FIRST: files created while the (possibly long) resync below runs
        # are queued as events and handled afterwards, instead of being missed
        bashio::log.info "Start inotifywait watch on ${SRC}"
        exec {fd}< <(inotifywait -m -e close_write -e moved_to -e delete -e moved_from --format '%e %f' "$SRC")

        # a new round: login problems are tried again
        FTPS_AUTH_FAILED="false"
        # remove the remote temp file of an upload a hard stop cut off, before new uploads reuse the names
        ftps_cleanup_interrupted || true

        # resync in case events were missed while the watch was down
        scan_backups "sync"
		STARTUP_SYNC="false"
        next_check=$(($(date +%s) + RESYNC_CHECK_INTERVAL))

        # handle queued and new events, check regularly whether anything is still not fully handled
        while true; do
            remaining=$((next_check - $(date +%s)))
            if [ "$remaining" -le 0 ]; then
                next_check=$(($(date +%s) + RESYNC_CHECK_INTERVAL))
                # a new round: login problems are tried again
                FTPS_AUTH_FAILED="false"
                # retry cleanup failed before (server unreachable); only local check if nothing is left
                ftps_cleanup_interrupted || true
                if scan_backups; then
                    bashio::log.info "Some backups are not fully handled yet, retrying"
                    scan_backups "sync"   # includes the deletion sync and state cleanup
                else
                    # nothing to upload, but a missed delete event may still have left a stale copy on the server
                    # note: compares local files only, connects to the server just if a deletion is actually pending
                    ftps_sync_deletions quiet || true
                    ftps_cleanup_state || true
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
    local f base total=0 unencrypted=0 uploaded=""
    for f in "${SRC}"/*.tar; do
        [ -e "$f" ] || continue
        total=$((total + 1))
        if [ "$(backup_encryption "$f")" != "encrypted" ]; then
            unencrypted=$((unencrypted + 1))
            # uploaded earlier, while unencrypted backups were still allowed: that copy stays on the server
            base=$(basename "$f")
            if [ "$ALLOW_UNENCRYPTED" != "true" ] && [ -f "${FTPS_STATE_DIR}/${base}" ]; then
                uploaded+="${uploaded:+, }${base}"
            fi
        fi
    done

    # nothing to report
    [ "$unencrypted" -gt 0 ] || return 0

    if [ "$ALLOW_UNENCRYPTED" = "true" ]; then
        bashio::log.warning "${unencrypted} of ${total} backups in ${SRC} are not recognised as encrypted: their uploads will contain secrets in plain text"
    else
        bashio::log.warning "${unencrypted} of ${total} backups in ${SRC} are not recognised as encrypted: they will not be uploaded"
    fi

    if [ -n "$uploaded" ]; then
        if [ "$FTPS_SYNC_DELETIONS" = "true" ]; then
            bashio::log.warning "Not encrypted, but uploaded earlier and still on the FTPs server: ${uploaded}. They are removed from the server once the backup is deleted here"
        else
            bashio::log.warning "Not encrypted, but uploaded earlier and still on the FTPs server: ${uploaded}. They are NOT removed automatically (ftps_sync_deletions is off): delete them on the server if unwanted"
        fi
    fi
}

# let's get started
bashio::log.info "Backup Watcher starting..."
bashio::log.info "Watching ${SRC} for new backup files"
# analyze and warn user, if required, without blocking startup by using "&"
warn_unencrypted_backups &
watch_backups
