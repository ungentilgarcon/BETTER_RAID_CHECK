# Debian Install Guide

This guide installs the RAID checker as a `systemd` oneshot service and configures concurrency limits per media class.
It also configures a `systemd` timer schedule (default: monthly).

## Requirements

- Debian with `bash`, `systemd`, `mdadm`
- Root privileges (`sudo`)

## Quick Install

From the project directory:

```bash
sudo ./install-debian.sh --hdd-limit 1 --ssd-limit 1 --nvm-limit 2
```

Bimonthly example (every 2 months):

```bash
sudo ./install-debian.sh --check-interval 2M --hdd-limit 1 --ssd-limit 1 --nvm-limit 2
```

Optional immediate run:

```bash
sudo ./install-debian.sh --hdd-limit 1 --ssd-limit 1 --nvm-limit 2 --start-now
```

## Installer Options

- `--hdd-limit N`: Max concurrent checks for HDD/mixed arrays.
- `--ssd-limit N`: Max concurrent checks for SSD arrays.
- `--nvm-limit N`: Max concurrent checks for NVM (NVMe) arrays.
- `--check-interval Xd|XM`: Schedule interval for timer checks (default `1M`).
- `--merge-ssd-nvm 0|1`: Treat SSD and NVM as one scheduling class.
- `--rotational-limit N`: Alias for `--hdd-limit`.
- `--nvme-limit N`: Alias for `--nvm-limit`.
- `--sleep-secs N`: Poll interval between status checks.
- `--dry-run 0|1`: Default dry-run mode in config file.
- `--skip-conflict-disable`: Keep existing cron/timer RAID checks enabled.
- `--start-now`: Start service after installation.

Interval examples:

- `30d`: every 30 days
- `60d`: every 60 days
- `1M`: monthly (default)
- `2M`: every 2 months

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

## Timer Status

Installer enables `raid-check-serial.timer` automatically.

Check timer schedule:

```bash
sudo systemctl cat raid-check-serial.timer
sudo systemctl list-timers --all | grep raid-check-serial
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

## Build a Debian Package

Build a `.deb` artifact from this repository:

```bash
./build-deb.sh --version 1.0.0
```

The package is created under `dist/`.

Install it:

```bash
sudo dpkg -i dist/better-raid-check_<version>_all.deb
```

## Interactive Package Configuration

When installing the `.deb`, `debconf` prompts for settings interactively:

- `check_interval` (`Xd` or `XM`)
- `MAX_HDD_CONCURRENT`, `MAX_SSD_CONCURRENT`, `MAX_NVM_CONCURRENT`
- `MERGE_SSD_NVM_CLASSES`
- `SLEEP_SECS`, `DRY_RUN`
- Disable conflicting cron/timer RAID checks
- Start a check immediately

Safety warning:

- If interval is longer than 2 months (or more than 60 days), install shows a confirmation question before proceeding.

Non-interactive installs:

- If `DEBIAN_FRONTEND=noninteractive` is used, package defaults are applied unless preseeds are provided.

Reconfigure later:

```bash
sudo dpkg-reconfigure better-raid-check
```

## Licensing

- Package includes GPL-3+ licensing metadata in `/usr/share/doc/better-raid-check/copyright`.
- `LICENSE` is installed under `/usr/share/doc/better-raid-check/LICENSE`.
