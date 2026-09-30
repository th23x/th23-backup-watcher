# th23 Backup Watcher – Home Assistant App

[![Add to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fth23x%2Fth23-backup-watcher)

Copying new backups to local folder or remote FTPs server

## About

Watches the `/backup` folder for new backups (not accessible from the dashboard), copies them to a local folder under `/share` (accessible from Home Assistant Core) and optionally uploads them to a remote server via FTPs (no SFTP access required).

## Features

- Backup routine remains defined by default Home Assistant settings
- Detects newly created backup files (`.tar`) automatically
- Automatic local copy to `/share/<folder>` where files are accessible for use in automations and scripts
- Automatic upload to remote server via FTPs, either explicit (STARTTLS) or implicit (no SFTP required)
- Number of backups is synced as defined in Home Assistant settings, backups deleted locally can also be deleted remotely
- Fires events as triggers for automations on success and failure

## Installation

1. In Home Assistant, go to **Settings → Apps → App Store**
2. Click **⋮ → Repositories** (top right) and add:
   `https://github.com/th23x/th23-backup-watcher`
3. Reload the store, open **Backup Watcher**, and click **Install**
4. Fill in the **Configuration** tab, then click **Start**
5. Recommended: Enable **Start on boot** and **Watchdog**

## Configuration

Open **Configuration** for all available settings and descriptions to each

## Events

`new_backup_copied` once local copy succeeded
`new_backup_copy_failed` in case local copy failed
`new_backup_uploaded` once FTPs upload succeeded
`new_backup_upload_failed` in case FTPs upload failed

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

- Credentials are stored only in the app configuration
- The FTPs server must support encrypted connections, plain FTP without is not supported
- Backups contain sensitive data: **Enable backup encryption in Home Assistant before uploading to a remote server!**

## Troubleshooting

Check the apps **Log** tab for error messages

## License

GPL-3.0 license
