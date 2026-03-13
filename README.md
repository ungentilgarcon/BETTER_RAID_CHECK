# RAID Check (Bounded Concurrency)

This setup runs Linux MD RAID `check` operations with configurable, media-aware concurrency limits:

- `MAX_ROTATIONAL_CONCURRENT` for HDD and mixed arrays
- `MAX_SSD_CONCURRENT` for SATA/SAS SSD arrays
- `MAX_NVME_CONCURRENT` for NVMe arrays

## Files

- `raid-check-serial.sh`: Orchestrates queueing, media classification, and check execution.
- `raid-check-serial.service`: `systemd` oneshot unit to run the script.
- `install-debian.sh`: Installs script + service on Debian and writes config file.

## Script Behavior

- Auto-discovers redundant MD arrays (`raid1`, `raid4`, `raid5`, `raid6`, `raid10`) if no arguments are provided.
- Accepts explicit arrays as arguments (`md0`, `/dev/md0`, `0`, etc.).
- Starts `check` only when array `sync_action` is `idle`.
- Classifies each array by member media:
	- Any rotational member => `rotational`
	- Else if any SSD member => `ssd`
	- Else if all non-rotational members are NVMe => `nvme`
- Polls until running checks complete, then starts additional queued arrays when slots are available.

## Install

Debian helper (recommended):

```bash
sudo ./install-debian.sh --rotational-limit 1 --ssd-limit 1 --nvme-limit 2
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
MAX_ROTATIONAL_CONCURRENT=1
MAX_SSD_CONCURRENT=1
MAX_NVME_CONCURRENT=1
EOF
```

Variables:

- `SLEEP_SECS`: Poll interval in seconds between state checks (default `20`).
- `DRY_RUN`: If `1`, prints intended actions without writing `sync_action`.
- `MAX_ROTATIONAL_CONCURRENT`: Max concurrent checks for rotational/mixed arrays.
- `MAX_SSD_CONCURRENT`: Max concurrent checks for SSD arrays.
- `MAX_NVME_CONCURRENT`: Max concurrent checks for NVMe arrays.

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
sudo MAX_ROTATIONAL_CONCURRENT=1 MAX_SSD_CONCURRENT=2 MAX_NVME_CONCURRENT=3 /usr/local/sbin/raid-check-serial.sh
```
