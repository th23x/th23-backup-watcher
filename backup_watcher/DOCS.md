# Backup Watcher

Backup Watcher watches the Home Assistant backup folder and uploads every new backup to an FTP server over **FTPs** (FTP with TLS). By default only encrypted backups are uploaded, see [Encryption](#encryption). It can optionally mirror deletions to the server, and it reports what it did through Home Assistant events, so you can build your own notifications.

## How it works

1. The app watches `/backup` (mounted read-only) for finished or moved-in `*.tar` backups. Everything else in that folder is ignored.
2. A new backup is only processed once its size has stayed the same for 5 seconds, so a backup that is still being written is never touched.
3. The backup is checked for encryption (see [Encryption](#encryption)).
4. The upload runs in these steps:
   1. **Space check:** if the server supports the `AVBL` command, the app makes sure there is enough free space.
   2. **Upload** to a temporary name (`<name>.tar.tmp`). With `ftps_atomic_upload` off, the upload goes straight to the final name instead.
   3. **Size check:** if the server supports `SIZE`, the uploaded size must match the original.
   4. **Rename** to the final name (skipped with `ftps_atomic_upload` off). The backup only appears under its real name on the server once it is complete and verified. If the server refuses to overwrite the file from an earlier upload of the same backup, the old version is moved aside while the new one is published and put back if that fails. The temporary file of a failed upload is removed again.
5. The app remembers each uploaded backup (name, size and modification time) for the current destination, see [Changing the destination](#changing-the-destination). Changed backups are uploaded again. A backup you delete on the server by hand is **not** uploaded again.

Servers that do not support `AVBL` or `SIZE` work fine. The app notices this once per run and skips those checks.

### Resync and retries

At every start, and then once an hour, the app compares `/backup` with what it has already uploaded and retries whatever is missing, such as a failed upload or a missed event. When nothing is left to upload, the hourly check also mirrors deletions that were missed (see [Deletion sync](#deletion-sync)). Backups younger than 60 seconds are left for the next round.

If the FTP server is not reachable, or refuses the login (wrong user or password), the round stops early instead of waiting for timeouts or repeating failed logins on every backup.

A backup whose upload failed is not retried at every check. The waiting time doubles with each failed attempt: the retries come at about the 1st, 2nd, 4th, 8th and 16th hourly check after the failure, and then about once a day. Every failure is logged with its attempt number and the time of the next retry (`attempt 3, next retry in about 4 h`). Three things end the waiting early:

- **A changed backup.** A backup with a new size or modification time counts as a new file and is tried at the next check.
- **A successful upload of any backup.** The server is obviously working again, so the other failed backups are retried at the next hourly check.
- **A restart of the app.** It forgets the waiting times, so after fixing the cause (wrong password, full disk, server back online) restarting the app retries immediately.

### Deletion sync

With `ftps_sync_deletions` enabled, a backup that disappears from Home Assistant (for example through its retention settings) is also removed from the server.

- Only files **this app uploaded** are ever deleted. It keeps a record of them, so other files in the same folder, or backups from another Home Assistant instance, are never touched.
- Nothing is deleted while `/backup` contains no backups at all, for example if the folder is unavailable. This also means the server copy of your very last backup stays.
- If the app's data is lost (for example after a reinstall), it forgets what it uploaded and deletes nothing.
- The same applies when you change the destination (see [Changing the destination](#changing-the-destination)): nothing is ever deleted on the old server.
- A deletion is mirrored when the backup disappears and again at the hourly check, so a missed event does not leave a stale copy until the next restart.

### Interrupted uploads

A stop request aborts a running upload right away, without waiting for it to finish. The temporary `.tar.tmp` file then stays on the server, as it does after a hard stop. The app removes it at its next start, and the hourly check tries again if the server could not be reached at that time. With `ftps_atomic_upload` off there is no temporary file.

## Configuration

| Option | Default | Description |
|---|---|---|
| `allow_unencrypted_backups` | `false` | Also upload backups that are not encrypted. Read [Encryption](#encryption) and [Secrets](#secrets-in-your-backups) first. |
| `ftps_host` | | Hostname, IPv4 address or IPv6 address in brackets (`[2001:db8::1]`) of the server. No `ftp://`, port or path. |
| `ftps_port` | `21` | `21` for explicit FTPs, usually `990` for implicit FTPs. |
| `ftps_user` | | FTP user name. |
| `ftps_password` | | FTP password. See [Secrets](#secrets-in-your-backups). |
| `ftps_implicit` | `false` | Implicit FTPs (TLS from the first byte, normally port 990). Off means explicit FTPs (`AUTH TLS` on port 21). A warning is logged for implicit FTPs on port 21. |
| `ftps_verify_cert` | `true` | Check the server certificate. Turning this off exposes your password and backups to man-in-the-middle attacks. For a self-signed certificate use `ftps_ca_file` instead. |
| `ftps_check_hostname` | `true` | Check that the certificate matches `ftps_host`. It can only be turned off together with `ftps_ca_file`, and then only that certificate is trusted. |
| `ftps_ca_file` | empty | Optional. Name of a PEM certificate file, in the app's own configuration folder, to trust for a self-signed certificate or a private CA. No slashes. Ignored while `ftps_verify_cert` is off. |
| `ftps_remote_dir` | `backups` | Folder on the server, relative to the FTP user's login folder (no leading `/`, no `..`). It is created if it does not exist. Leave empty to upload directly into the login folder. |
| `ftps_sync_deletions` | `false` | Mirror deletions to the server, see [Deletion sync](#deletion-sync). |
| `ftps_atomic_upload` | `true` | Upload under a temporary name and rename afterwards. Turn it off only for servers that do not allow renaming. A failed upload can then leave an incomplete file under the final name until the next attempt replaces it. |

Plain, unencrypted FTP is never used. If the server does not offer TLS, the connection fails rather than sending the password in the clear. Only TLS 1.2 or newer is accepted, so a server that offers nothing newer than TLS 1.0 or 1.1 cannot connect.

### Changing the destination

The app's records of what it has uploaded belong to one destination: the combination of `ftps_host`, `ftps_user` and `ftps_remote_dir`. If you change any of them (upper and lower case in the host name and a trailing `/` in the folder do not count), the app forgets its records at its next start, logs `FTPs destination changed`, and uploads all existing backups to the new destination.

- Copies on the old destination are not touched or deleted, not even by the deletion sync. Clean them up yourself.
- Changing the port, the password or the TLS settings does not count as a new destination.
- Changing back later uploads everything to the old destination again.

### Where to put the CA file

Put the file into the app's own configuration folder, which is mounted read-only into the app. On the host it appears as `/addon_configs/<repository id>_backup_watcher` (for example through the `addon_configs` network share or SSH), and `ftps_ca_file` is just the file name inside it. A symbolic link pointing outside this folder is refused.

### Configuration problems

If the configuration is invalid (for example an empty host, a missing CA file, or a line break in a text value), the app logs the problems and **stops without restarting itself**. Fix the configuration and start the app again.

## Events

The app fires Home Assistant events on the Home Assistant event bus. Use them in automations, or watch them under *Developer tools → Events → Listen to events*.

| Event type | Fired when |
|---|---|
| `new_backup_uploaded` | A backup was uploaded, verified and published under its final name. |
| `new_backup_upload_failed` | An upload failed. Fired for the first failure of a backup and again whenever the reason changes, not for every retry. |
| `new_backup_skipped` | A backup was deliberately **not** uploaded. |

No other events exist. Deletions, retries and cleanups are only logged.

### Payload

Every event carries the same keys:

| Key | Description |
|---|---|
| `filename` | File name of the backup, for example `a1b2c3d4.tar`. |
| `path` | Where the backup is. For `new_backup_uploaded` and `new_backup_upload_failed` this is the **server** path: `ftps_remote_dir` plus the file name, relative to the login folder (`backups/a1b2c3d4.tar`, or just `a1b2c3d4.tar` if `ftps_remote_dir` is empty). For `new_backup_skipped` it is the **local** path inside the app (`/backup/a1b2c3d4.tar`). |
| `timestamp` | UTC time in ISO 8601 form (`2026-10-03T15:16:38Z`). For `new_backup_uploaded` it is the time the upload started, for `new_backup_upload_failed` the time the failure was recorded (after the attempt), and for `new_backup_skipped` the time the skip was detected. |
| `reason` | Only on `new_backup_upload_failed` and `new_backup_skipped`, see below. Never present on `new_backup_uploaded`. |

Examples of the actual event data:

```json
{"filename":"a1b2c3d4.tar","path":"backups/a1b2c3d4.tar","timestamp":"2026-10-03T15:16:38Z"}
```

```json
{"filename":"a1b2c3d4.tar","path":"backups/a1b2c3d4.tar","timestamp":"2026-10-03T15:16:38Z","reason":"insufficient_space"}
```

```json
{"filename":"a1b2c3d4.tar","path":"/backup/a1b2c3d4.tar","timestamp":"2026-10-03T15:16:45Z","reason":"not_encrypted"}
```

### Reasons

**`new_backup_upload_failed`**

| `reason` | Meaning |
|---|---|
| `insufficient_space` | The server has too little room. Either it reported less free space than the backup needs, or it rejected the upload with a storage message (FTP codes 452 or 552, or 450, 451 or 550 with text like "disk full", "no space", "insufficient storage" or "quota exceeded"). |
| `upload_error` | Anything else. Examples are server not reachable, login refused, TLS or certificate problems, a size mismatch after upload, a refused rename, and timeouts. The cause is in the app log. The event deliberately does not carry the raw error text. |

**`new_backup_skipped`**

| `reason` | Meaning |
|---|---|
| `not_encrypted` | The backup is not encrypted and `allow_unencrypted_backups` is off. |
| `unreadable` | No valid `backup.json` could be read from the file: it is damaged, not a Home Assistant backup, or its encryption flag is missing. This is only reported for files older than 60 seconds, so a backup that is still being finished does not trigger it. |

### How often events fire

- **`new_backup_upload_failed`** fires when a backup fails for the first time, and again only if the reason changes (for example from `upload_error` to `insufficient_space`). Retries that fail for the same reason are logged but do not fire again, so a notification automation does not notify every hour. When a retry finally works, you get `new_backup_uploaded`. The app forgets this when it restarts, so after a restart the next failure of a backup that is still missing fires again. With the server down or a refused login, the round stops after the first backup, so only that backup is reported until the next round.
- **`new_backup_skipped`** fires once per backup and file state. The app forgets this when it restarts, so every skipped backup is reported once more after a restart or update.
- Events are fired once and not queued. If Home Assistant Core is unreachable at that moment (for example while restarting), the event is lost and only a warning appears in the app log. A retry that fails for the same reason does not fire a second event, so do not use the failure event as your only alarm. Also look at the app log or the FTP server from time to time.

### Automation example

```yaml
- alias: Backup upload problem
  triggers:
    - trigger: event
      event_type: new_backup_upload_failed
  actions:
    - action: persistent_notification.create
      data:
        notification_id: "backup_watcher_{{ trigger.event.data.filename }}"
        title: Backup upload failed
        message: >-
          {{ trigger.event.data.filename }} could not be uploaded:
          {{ 'the server is out of space' if trigger.event.data.reason == 'insufficient_space'
             else 'see the Backup Watcher log' }}

- alias: Backup upload problem solved
  triggers:
    - trigger: event
      event_type: new_backup_uploaded
  actions:
    - action: persistent_notification.dismiss
      data:
        notification_id: "backup_watcher_{{ trigger.event.data.filename }}"
```

The failure event does not repeat for the same reason, so the notification stays until the backup has been uploaded. The second automation then removes it. If a backup is deleted in Home Assistant before it could be uploaded, the notification stays until you dismiss it yourself. To react to skipped backups, use `event_type: new_backup_skipped` and the `reason` and `filename` values the same way.

## Encryption

Home Assistant can encrypt backups with a password (the encryption key). Encrypted backups protect everything inside them: passwords, tokens and `secrets.yaml`.

By default the app uploads **only encrypted backups**. It reads the `protected` flag in the backup's `backup.json`, which Home Assistant stores unencrypted next to the encrypted contents. The app cannot look inside an encrypted archive, so it relies on that flag.

- If `allow_unencrypted_backups` is **off**, unencrypted or unreadable backups are skipped and reported with the `new_backup_skipped` event and a warning in the log. At start-up, one summary warning tells how many backups are affected.
- If it is **on**, unencrypted backups are uploaded with a warning in the log.
- Turning the option off does not remove unencrypted backups that were uploaded earlier. The start-up log lists them. They are removed by the deletion sync once the backup is deleted in Home Assistant, otherwise delete them on the server yourself.
- A changed setting takes effect after the app is restarted.

## Secrets in your backups

**The backups this app uploads contain this app's own configuration, including the FTPs password.**

Home Assistant backups include the installed apps together with their settings. For this app that means `ftps_host`, `ftps_user` and `ftps_password`. The backups it uploads are those same backups, so the password for the server is stored in the files on that server. Beyond the app's own settings, backups hold your other secrets as well: tokens, `secrets.yaml` and the credentials of other apps.

What this means for you:

1. **Keep backups encrypted.** This is the default (`allow_unencrypted_backups` off). With an unencrypted backup, anyone who can read the file, on the server or in any copy, can read the FTP credentials and everything else in plain text.
2. **Use a dedicated FTP account** that can only reach the backup folder. It needs rights to upload, to rename (unless `ftps_atomic_upload` is off) and to delete the app's own temporary files (`*.tar.tmp`, `*.tar.old`), otherwise leftovers of failed uploads stay on the server. Deleting the backups themselves is only needed with `ftps_sync_deletions` on. Use a password you use nowhere else, because it is part of your backups.
3. **If a backup file leaks, change the secrets.** That includes the FTP password and anything in `secrets.yaml`. Older backups on the server keep the old password, which stops working once you change it.
4. **Keep the encryption key apart from the backups**, for example in a password manager or the emergency kit, and never on the same FTP server. Without it an encrypted backup cannot be restored.
5. **Optionally leave this app out of your backups** when you create them manually or choose which apps to include. Then the FTPs settings are not part of the files, but after a restore you have to enter them again.

What the app itself does to keep the password safe:

- It is never written to the log. The app masks it, even in error messages.
- It is passed to the FTP client through standard input, so it does not show up in the process list.
- TLS is mandatory and there is no fallback to plain FTP. Certificate verification is on unless you turn it off.

## Troubleshooting

| Log message | What it means |
|---|---|
| `Invalid configuration: ...` | An option is wrong. The app stopped on purpose. Fix it and start the app again. |
| `FTPs: failed to upload <file> (<reason>): ... - attempt <n>, next retry in about <h> h` | The upload failed. The last lines of the FTP client output follow, with the password masked. Attempt number and wait follow the client output. |
| `FTPs server not reachable: remaining uploads wait for the next check` | The server could not be reached, so the round stopped. The failed backup is retried after a waiting time that grows with each failure (see [Resync and retries](#resync-and-retries)). Restart the app to retry at once. |
| `FTPs login refused: check ftps_user and ftps_password ...` | The server refused the login. The round stops after the first attempt, so a wrong password does not hammer the server. Fix the credentials and restart the app to retry at once, otherwise the next retry follows after the waiting time. |
| `FTPs destination changed (...)` | You changed host, user or folder. See [Changing the destination](#changing-the-destination). |
| `<file> is not encrypted: skipping it` | See [Encryption](#encryption). |
| `<file> could not be read as a Home Assistant backup` | The file has no valid `backup.json`. |
| `FTPs: server does not report free space` / `file sizes` | Informational. That check is skipped for this server. |
| `ftps_implicit is on, but port 21 ...` | Implicit FTPs normally uses port 990. |
| Certificate errors | Provide the server certificate or CA with `ftps_ca_file`. Avoid turning `ftps_verify_cert` off. |
| A TLS handshake error that mentions the protocol version | The server only offers TLS 1.0 or 1.1. The app is set up to require TLS 1.2 or newer, so enable it on the server. |
| `mv: Access failed: 550 ...` in a failed upload | The server accepted the upload, but the account is not allowed to rename the file. Give it rename rights, or turn off `ftps_atomic_upload`. |

## Limitations

- Only FTPs is supported (explicit and implicit), with TLS 1.2 or newer. There is no plain FTP and no SFTP.
- One server and one target folder.
- Fixed timings: 5 seconds of stable size, 60 seconds minimum age for resync, one check per hour. Failed uploads are retried after 1, 2, 4, 8 and 16 hours, then daily.
- Only `*.tar` files in the backup folder are handled.

## Upgrading from earlier versions

Earlier versions could also copy backups into `/share`. That feature is gone, and with it the `new_backup_copied` and `new_backup_copy_failed` events and the `local_copy_*` options. Automations that used them need to be changed.

Also check these when updating to 2.0.0 (details in the changelog):

- `ftps_remote_dir` is now relative to the FTP login folder and must not start with `/`. Change `/backups` to `backups`. Files that were already uploaded stay where they are.
- FTPs is required: until host, user and password are set, the app stops with `Invalid configuration`.
- Host names, user names, the remote folder and the CA file name are validated when you save them.
- TLS 1.2 or newer is required.
- `new_backup_upload_failed` no longer fires on every retry, only for the first failure of a backup and when the reason changes. Automations that notify on it will notify less often.
