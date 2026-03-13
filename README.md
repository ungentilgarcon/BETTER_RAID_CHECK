# RAID Check (Bounded Concurrency)

This setup runs Linux MD RAID `check` operations with configurable, media-aware concurrency limits:

- `MAX_HDD_CONCURRENT` for HDD and mixed arrays
- `MAX_SSD_CONCURRENT` for SATA/SAS SSD arrays
- `MAX_NVM_CONCURRENT` for NVM (NVMe) arrays

Optional:

- `MERGE_SSD_NVM_CLASSES=1` to treat SSD and NVM as one scheduling class (`ssd`)

## Files

- `raid-check-serial.sh`: Orchestrates queueing, media classification, and check execution.
- `raid-check-serial.service`: `systemd` oneshot unit to run the script.
- `install-debian.sh`: Installs script + service on Debian and writes config file.

## Script Behavior

- Auto-discovers redundant MD arrays (`raid1`, `raid4`, `raid5`, `raid6`, `raid10`) if no arguments are provided.
- Accepts explicit arrays as arguments (`md0`, `/dev/md0`, `0`, etc.).
- Starts `check` only when array `sync_action` is `idle`.
- Classifies each array by member media:
	- Any rotational member => `hdd`
	- Else if any SSD member => `ssd`
	- Else if all non-rotational members are NVMe => `nvm`
- Mixed arrays are assigned to the least-fast class (`hdd` > `ssd` > `nvm`).

Scheduler safety:

- Installer disables and masks conflicting RAID-check `systemd` timers (for example `mdcheck_*` and similar check/scrub timers).
- Installer disables conflicting cron/anacron RAID-check entries and files.
- Polls until running checks complete, then starts additional queued arrays when slots are available.

## Install

Debian helper (recommended):

```bash
sudo ./install-debian.sh --hdd-limit 1 --ssd-limit 1 --nvm-limit 2
```

Manual install:

```bash
sudo install -m 0755 raid-check-serial.sh /usr/local/sbin/raid-check-serial.sh
sudo install -m 0644 raid-check-serial.service /etc/systemd/system/raid-check-serial.service
sudo systemctl daemon-reload
```

## Optional Runtime Config

The service reads optional variables from `/etc/default/raid-check-serial`.

Example:

```bash
sudo tee /etc/default/raid-check-serial >/dev/null <<'EOF'
SLEEP_SECS=20
DRY_RUN=0
MAX_HDD_CONCURRENT=1
MAX_SSD_CONCURRENT=1
MAX_NVM_CONCURRENT=1
MERGE_SSD_NVM_CLASSES=0
EOF
```

Variables:

- `SLEEP_SECS`: Poll interval in seconds between state checks (default `20`).
- `DRY_RUN`: If `1`, prints intended actions without writing `sync_action`.
- `MAX_HDD_CONCURRENT`: Max concurrent checks for HDD/mixed arrays.
- `MAX_SSD_CONCURRENT`: Max concurrent checks for SSD arrays.
- `MAX_NVM_CONCURRENT`: Max concurrent checks for NVM arrays.
- `MERGE_SSD_NVM_CLASSES`: If `1`, NVM arrays are treated as `ssd` class.

Backward compatibility:

- `MAX_ROTATIONAL_CONCURRENT` is accepted as an alias for `MAX_HDD_CONCURRENT`.
- `MAX_NVME_CONCURRENT` is accepted as an alias for `MAX_NVM_CONCURRENT`.

## Run

Run via `systemd`:

```bash
sudo systemctl start raid-check-serial.service
sudo systemctl status raid-check-serial.service
```

Run script directly (all eligible arrays):

```bash
sudo /usr/local/sbin/raid-check-serial.sh
```

Run script directly (specific arrays):

```bash
sudo /usr/local/sbin/raid-check-serial.sh md0 /dev/md1
```

Dry run:

```bash
sudo DRY_RUN=1 /usr/local/sbin/raid-check-serial.sh
```

Override limits for one run:

```bash
sudo MAX_HDD_CONCURRENT=1 MAX_SSD_CONCURRENT=2 MAX_NVM_CONCURRENT=3 /usr/local/sbin/raid-check-serial.sh
```
