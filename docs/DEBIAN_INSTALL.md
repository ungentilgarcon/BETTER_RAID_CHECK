# Debian Install Guide

This guide installs the RAID checker as a `systemd` oneshot service and configures concurrency limits per media class.

## Requirements

- Debian with `bash`, `systemd`, `mdadm`
- Root privileges (`sudo`)

## Quick Install

From the project directory:

```bash
sudo ./install-debian.sh --hdd-limit 1 --ssd-limit 1 --nvm-limit 2
```

Optional immediate run:

```bash
sudo ./install-debian.sh --hdd-limit 1 --ssd-limit 1 --nvm-limit 2 --start-now
```

## Installer Options

- `--hdd-limit N`: Max concurrent checks for HDD/mixed arrays.
- `--ssd-limit N`: Max concurrent checks for SSD arrays.
- `--nvm-limit N`: Max concurrent checks for NVM (NVMe) arrays.
- `--merge-ssd-nvm 0|1`: Treat SSD and NVM as one scheduling class.
- `--rotational-limit N`: Alias for `--hdd-limit`.
- `--nvme-limit N`: Alias for `--nvm-limit`.
- `--sleep-secs N`: Poll interval between status checks.
- `--dry-run 0|1`: Default dry-run mode in config file.
- `--skip-conflict-disable`: Keep existing cron/timer RAID checks enabled.
- `--start-now`: Start service after installation.

## Config File

Installer writes `/etc/default/raid-check-serial`:

```bash
SLEEP_SECS=20
DRY_RUN=0
MAX_HDD_CONCURRENT=1
MAX_SSD_CONCURRENT=1
MAX_NVM_CONCURRENT=2
MERGE_SSD_NVM_CLASSES=0
```

You can edit this file later and run:

```bash
sudo systemctl daemon-reload
```

## Run and Check

Run now:

```bash
sudo systemctl start raid-check-serial.service
```

Check result:

```bash
sudo systemctl status raid-check-serial.service
```

## Notes

- Arrays are classified by their member devices.
- If an array has any rotational member, it is treated as `hdd`.
- Mixed non-rotational arrays (SSD + NVMe) are treated as `ssd` for conservative scheduling.
- Installer disables and masks conflicting RAID-check timers and cron entries by default.
