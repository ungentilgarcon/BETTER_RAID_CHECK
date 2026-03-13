# RAID Check (Bounded Concurrency)

This setup runs Linux MD RAID `check` operations with configurable, media-aware concurrency limits:
Default check policy was too aggressive for my setup so I implmented this in a way that is less sollicitating for the small PCIE X1 card I use for hdds.

- `MAX_HDD_CONCURRENT` for HDD and mixed arrays
- `MAX_SSD_CONCURRENT` for SATA/SAS SSD arrays
- `MAX_NVM_CONCURRENT` for NVM (NVMe) arrays

Optional:

- `MERGE_SSD_NVM_CLASSES=1` to treat SSD and NVM as one scheduling class (`ssd`)

## Files

- `raid-check-serial.sh`: Orchestrates queueing, media classification, and check execution.
- `raid-check-serial.service`: `systemd` oneshot unit to run the script.
- `raid-check-serial.timer`: `systemd` timer unit that schedules checks (default: monthly).
- `install-debian.sh`: Installs script + service on Debian and writes config file.
- `build-deb.sh`: Builds a Debian package (`.deb`) from this repository.

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
- Installer enables `raid-check-serial.timer` by default.
- Polls until running checks complete, then starts additional queued arrays when slots are available.

Schedule policy:

- Default schedule is monthly (`--check-interval 1M`).
- You can set custom interval with `--check-interval Xd|XM`.
- Examples: `30d`, `60d`, `1M`, `2M`.

## Install

Debian helper (recommended):

```bash
sudo ./install-debian.sh --hdd-limit 1 --ssd-limit 1 --nvm-limit 2
```

Install with checks every 2 months:

```bash
sudo ./install-debian.sh --check-interval 2M --hdd-limit 1 --ssd-limit 1 --nvm-limit 2
```

Manual install:

```bash
sudo install -m 0755 raid-check-serial.sh /usr/local/sbin/raid-check-serial.sh
sudo install -m 0644 raid-check-serial.service /etc/systemd/system/raid-check-serial.service
sudo install -m 0644 raid-check-serial.timer /etc/systemd/system/raid-check-serial.timer
sudo systemctl daemon-reload
sudo systemctl enable --now raid-check-serial.timer
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

Check scheduled timer:

```bash
sudo systemctl status raid-check-serial.timer
sudo systemctl list-timers --all | grep raid-check-serial
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

## Build Debian Package

Build a `.deb` package artifact:

```bash
./build-deb.sh --version 1.0.0
```

Output will be written under `dist/`.

Install package:

```bash
sudo dpkg -i dist/better-raid-check_<version>_all.deb
```

During package install, interactive prompts let you set:

- Check interval (`Xd` or `XM`)
- Concurrent checks for `HDD`, `SSD`, `NVM`
- `MERGE_SSD_NVM_CLASSES`
- `SLEEP_SECS`, `DRY_RUN`
- Whether to disable conflicting schedulers
- Whether to start a check immediately

If interval is greater than 2 months (or more than 60 days), installer shows a warning and asks for confirmation before continuing.

Re-run interactive settings later:

```bash
sudo dpkg-reconfigure better-raid-check
```
