# th23 Backup Watcher – Home Assistant App

[![Add to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fth23x%2Fth23-backup-watcher)

Uploads and synchronizes backups to remote FTPs server

## About

Watches the `/backup` folder for new backups (not accessible from the dashboard) and uploads them to a remote server via FTPs (no SFTP access required). Option to keep remote files in sync with those at Home Assistant server, deleting remotely once removed locally, eg for keeping last 3 backups only.

## Features

- Backup routine remains defined by default Home Assistant settings
- Detects newly created backup files (`.tar`) automatically
- Automatic upload to remote server via FTPs, either explicit (`AUTH TLS`) or implicit (no SFTP required)
- Optional deletion sync: backups deleted in Home Assistant (for example by its retention settings) are also deleted on the server
- Only encrypted backups are uploaded by default, unencrypted ones are skipped and reported unless you allow them
- Fires events as triggers for own automations on success and failure

## Installation

1. In Home Assistant, go to **Settings → Apps → App Store**
2. Click **⋮ → Repositories** (top right) and add:
   `https://github.com/th23x/th23-backup-watcher`
3. Reload the store, open **Backup Watcher**, and click **Install**
4. Fill in the **Configuration** tab, then click **Start**
5. Recommended: Enable **Start on boot** and **Watchdog**

## Configuration

Open **Configuration** tab in Home Assistant under `Settings` -> `Apps` -> `Backup Watcher` for all available settings and descriptions to each

## Events

- `new_backup_uploaded` once a backup was uploaded, verified and published under its final name
- `new_backup_upload_failed` in case an upload attempt failed
- `new_backup_skipped` once a backup was deliberately **not** uploaded

For more details about events, see **Documentation** tab in Home Assistant under `Settings` -> `Apps` -> `Backup Watcher`

Example automation utilizing such event:

```yaml
triggers:
  - trigger: event
    event_type: new_backup_upload_failed
actions:
  - action: notify.notify
    data:
      message: "Backup upload failed: {{ trigger.event.data }}"
```

## Notes

- The FTPs server must support TLS 1.2 or newer, plain FTP is not supported
- Backups contain sensitive data: **Enable backup encryption in Home Assistant before uploading to a remote server!**
- The FTPs password is stored in the app configuration, which is part of your Home Assistant backups, see **Secrets in your backups** in the Documentation tab

## Troubleshooting

Check the app's **Log** tab for error messages, and the **Troubleshooting** section of the Documentation tab for what they mean

## License

GPL-3.0 license
