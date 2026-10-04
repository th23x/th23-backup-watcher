# Changelog

## 2.0.0

This release removes the local copy feature. The app now does one thing: upload Home Assistant backups to an FTP server over FTPs.

### Action required when updating

- **Local copy is gone.** The options `local_copy_enabled`, `local_copy_subdir` and `local_sync_deletions` no longer exist, and the app no longer has access to `/share`. Copies made by earlier versions stay in `/share/<subfolder>` and are no longer maintained, so delete them yourself if you do not need them. Automations that use the `new_backup_copied` or `new_backup_copy_failed` events must be changed, for example to use `new_backup_uploaded`.
- **FTPs is now required.** The `ftps_enabled` option is gone. Until host, user and password are set, the app logs `Invalid configuration` and stops without restarting itself. If you only used the local copy, this app no longer does anything for you.
- **`ftps_remote_dir` is now relative to the FTP login folder** and must not start with `/`. The default is `backups` (it was `/backups`). Change an existing `/backups` value to `backups`: an absolute path is rejected, and the app does not start until you fix it. Files that were already uploaded stay where they are. The `path` in upload events changes the same way, from `/backups/<file>` to `backups/<file>`.
- **Options are validated when you save them.** Host names, user names, the remote folder and the CA file name must match the allowed format. For example, underscores in host names, a `..` segment in the remote folder, or a `/` in the CA file name are rejected.
- **Failure events no longer repeat.** `new_backup_upload_failed` fires for the first failure of a backup and again only if the reason changes, no longer on every retry. Automations that counted these events, for example to notify every hour, see fewer of them. A later success still fires `new_backup_uploaded`.
- **TLS 1.2 or newer is required.** A server that only offers TLS 1.0 or 1.1 can no longer connect, and the log shows a handshake error such as `SSL_connect: tlsv1 alert protocol version`. Enable TLS 1.2 on the server.

### Removed

- Copying backups to `/share`, including the local free-space check, the local size verification and the local deletion sync.
- The options `local_copy_enabled`, `local_copy_subdir`, `local_sync_deletions` and `ftps_enabled`.
- The events `new_backup_copied` and `new_backup_copy_failed`. The reason `size_mismatch`, which only existed for copies, is gone with them.
- The `/share` mapping.

### Added

- **`new_backup_skipped` event** with the reasons `not_encrypted` and `unreadable`. Before, a skipped backup was only mentioned in the log. It fires once per backup and file state.
- **`ftps_check_hostname` option.** It can only be turned off together with `ftps_ca_file`, so that only your own certificate is trusted.
- **`ftps_atomic_upload` option.** Turn it off only for servers that do not allow renaming.
- **`ftps_remote_dir` may be empty** to upload directly into the FTP login folder. The `path` in upload events is then just the file name.
- Configuration checks at start. Invalid settings stop the app with a clear message instead of silently disabling the upload.
- Warnings for risky settings: certificate verification off, hostname check off, atomic upload off, and implicit FTPs on port 21.
- **Server-down and login handling.** After a failure the app checks whether the server can be reached. If it cannot, or if the server refuses the login (wrong user or password), the current round stops early instead of waiting for timeouts or repeating failed logins on every backup, and the deletion sync is skipped. The failed backup is retried after a growing wait, see **Retry back-off**. A refused login costs one failed login per round.
- **Cleanup after an interrupted upload.** A temporary file left on the server when the app is stopped during an upload is removed at the next start. If the server cannot be reached then, the hourly check tries again.
- **Safer replacement of a changed backup.** The previous version on the server is moved aside while the new one is published, and is put back if publishing fails. Before, it was removed first.
- **Retry back-off.** A backup whose upload failed is retried after a growing wait (about 1, 2, 4, 8 and 16 hours, then about once a day) instead of at every hourly check, so a lasting problem such as a wrong password no longer costs several logins per backup every hour. A changed backup, a successful upload of another backup, or an app restart ends the wait early. The log shows the attempt number and the next retry.
- The start-up log lists backups that were uploaded earlier while unencrypted backups were still allowed, and says whether they will be removed.
- The hourly check now also mirrors deletions that were missed, when nothing is left to upload.

### Changed

- The encryption check now runs after a backup has finished being written. A backup without a readable `backup.json` that is younger than 60 seconds is checked again later instead of being skipped.
- The encryption result is remembered per backup. Only a JSON `true` or `false` for the encryption flag counts, and `backup.json` is read up to 256 KiB.
- The upload size check is retried up to three times. A backup whose size cannot be verified is not published.
- Error messages from the FTP client are logged with the password masked.
- The connection requires TLS 1.2 or newer. The minimum is now set explicitly, so it no longer depends on how the FTP client was built.
- Once the server is known to report file sizes, the size is requested in the same connection as the upload, which saves one login per upload.
- A stop request now ends a running upload at once. Before, the app waited for the upload to finish.
- The CA file must be a PEM file inside the app's own configuration folder. A symbolic link pointing outside that folder is refused.
- Changing `ftps_host`, `ftps_user` or `ftps_remote_dir` makes the app upload all existing backups to the new destination. Copies on the old destination are not removed.
- The Docker base image is pinned to `3.24` instead of `latest`.
- Log messages say "app" instead of "add-on".

### Fixed

- A failed rename (for example on an account without rename permission) deleted the previous copy on the server and left a full-size `.tar.tmp` behind that was never removed. The previous copy is no longer deleted before the new one is in place, and the temporary file is removed after any failed upload, rename or size check.
- Stopping the app could leave the file watcher (`inotifywait`) running as an orphan process.
- A short network problem during the size check could switch size verification off until the next restart. The app now concludes that a server has no `SIZE` command only from the server's own answer.
- Words or numbers in an error message, such as a user name, a folder name (also when the server echoes it in its reply) or a byte count containing "quota", "no space" or the number 452 or 552, could be reported as `insufficient_space`. Only the server's actual reply counts now.

## 1.1.0

### Added

- `allow_unencrypted_backups` (off by default): only encrypted backups are copied or uploaded unless you allow otherwise.
- `ftps_ca_file`: trust a self-signed server certificate or a private CA, from the app's configuration folder.
- `local_sync_deletions`: the deletion sync for local copies can be switched off.

### Changed

- The Docker image moved to a supported Alpine base and no longer relies on the deprecated `build.yaml`. `jq` and `tar` are installed explicitly.

## 1.0.0

- First release: watches the backup folder, copies new backups to `/share` and uploads them to an FTP server over FTPs.
