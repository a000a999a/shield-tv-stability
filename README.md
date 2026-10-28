# shield-tv-stability

Tools for running an NVIDIA Shield TV as a stable NAS + Plex server.

Covers the root cause of mysterious CIFS mount failures during large file transfers, a one-line rsync fix, a continuous logcat capture service, and an auto-recovery mount watchdog for *arr stacks.

---

## The problem: why transfers kill your mount

If you use an NVIDIA Shield TV as a network storage device (SMB share) and copy large files to it, you may see:

- CIFS mounts on your Linux client become unresponsive mid-transfer
- `rsync` processes stuck in **D state** (uninterruptible sleep), unkillable with `kill -9`
- `/mnt/...` hanging forever on any access
- Radarr/Sonarr/other arr containers exiting because their volume is gone

The root cause is an OOM (out-of-memory) chain:

```
Large write →  smbd write buffers fill RAM
            →  Android OOM killer fires
            →  kills com.nvidia.shield.smbserver:sambaserver
            →  CIFS mount on client loses its connection
            →  any rsync/write in progress enters D state (kernel uninterruptible wait)
            →  mount stays wedged until manually recovered
```

The Shield has 3 GB RAM. During an uncapped rsync, available memory can drop from ~1.4 GB to under 100 MB in under two minutes. The Samba process is a soft target for the OOM killer.

### Fix: cap your rsync write rate

```bash
rsync --bwlimit=10M ...
```

10 MB/s keeps available RAM at ~1.25–1.4 GB during sustained transfers. Gigabit LAN is ~125 MB/s, so this is a deliberate cap to prevent buffer bloat — not a network limitation.

If you run multiple concurrent rsyncs, cap each one. Sequential transfers (one at a time) are safer; with `--bwlimit` they are stable even alongside active Plex streaming.

### Recovering a wedged mount

If the mount is already wedged:

```bash
sudo umount -l /mnt/yourshare   # lazy unmount — detaches from namespace, unblocks D-state rsync
sudo systemctl restart mnt-yourshare.mount
```

---

## Logcat capture service

Continuously captures Shield logcat output to daily rolling log files on your Linux host. Useful for diagnosing crashes, OOM events, and Samba restarts after the fact.

**Prerequisites:** `adb` installed on your Linux host, ADB over Wi-Fi enabled on the Shield (`adb connect <shield-ip>:5555` authorized at least once).

### Setup

1. Edit `logcat/capture.sh` — set `SHIELD_IP` and `LOG_DIR` at the top.

2. Copy the script and install the service:

```bash
chmod +x logcat/capture.sh
cp logcat/shield-logcat.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now shield-logcat.service
```

3. Check it's running:

```bash
systemctl --user status shield-logcat.service
tail -f ~/logs/shield/logcat-$(date +%Y-%m-%d).log
```

Log files rotate daily. Files older than 14 days are deleted automatically.

---

## Mount watchdog

A systemd timer that polls your CIFS mount every 30 seconds. If it's inaccessible, it restarts the systemd mount unit and, once the mount recovers, revives any Docker Compose services (radarr, sonarr, etc.) that exited while the mount was down.

**Prerequisites:** `docker` + Docker Compose, a systemd `.mount` unit for the CIFS share, `sudo` NOPASSWD rule (see below).

### Setup

1. Edit `watchdog/mount-watchdog.sh` — set the config block at the top:

```bash
MOUNT="/mnt/yourshare"                    # your mount point
SYSTEMD_UNIT="mnt-yourshare.mount"        # systemd unit (path with - replacing /)
COMPOSE_FILE="$HOME/.../docker-compose.yml"
SERVICES="radarr sonarr"                  # services to restart after recovery
```

2. Add a passwordless sudo rule so the watchdog can restart the mount unit without a TTY:

```bash
sudo visudo -f /etc/sudoers.d/shield-watchdog
```

Paste (adjust username and unit name):

```
youruser ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart mnt-yourshare.mount
youruser ALL=(ALL) NOPASSWD: /usr/bin/umount -l /mnt/yourshare
```

See `watchdog/sudoers.example` for the template.

3. Install:

```bash
chmod +x watchdog/mount-watchdog.sh
cp watchdog/shield-mount-watchdog.service ~/.config/systemd/user/
cp watchdog/shield-mount-watchdog.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now shield-mount-watchdog.timer
```

4. Verify:

```bash
systemctl --user status shield-mount-watchdog.timer
tail -f ~/logs/shield/mount-watchdog.log
```

---

## Optional: debloat for Plex-only use

If you use the Shield exclusively as a Plex server + NAS (no streaming apps, no Google Assistant), the following packages can be safely removed. These are **not** system-critical and are fully reversible.

```bash
# Remove
adb shell pm uninstall --user 0 com.android.hotwordenrollment.okgoogle
adb shell pm uninstall --user 0 com.android.hotwordenrollment.xgoogle
adb shell pm uninstall --user 0 com.google.android.backdrop
adb shell pm uninstall --user 0 com.google.android.feedback
adb shell pm uninstall --user 0 com.google.android.onetimeinitializer
adb shell pm uninstall --user 0 com.google.android.play.games
adb shell pm uninstall --user 0 com.google.android.sss.authbridge
adb shell pm uninstall --user 0 com.google.android.videos
adb shell pm uninstall --user 0 com.amazon.amazonvideo.livingroom
adb shell pm uninstall --user 0 com.netflix.ninja
adb shell pm uninstall --user 0 com.google.android.youtube.tv
adb shell pm uninstall --user 0 com.android.dreams.basic
adb shell pm uninstall --user 0 com.android.bluetoothmidiservice
adb shell pm uninstall --user 0 com.android.captiveportallogin
adb shell pm uninstall --user 0 com.android.cts.ctsshim
adb shell pm uninstall --user 0 com.android.wallpaperbackup
adb shell pm uninstall --user 0 com.google.android.syncadapters.calendar
adb shell pm uninstall --user 0 com.google.android.partnersetup
adb shell pm uninstall --user 0 com.google.android.overlay.modules.permissioncontroller
adb shell pm uninstall --user 0 com.google.android.tts

# Keep (required for phone remote app)
# com.google.android.tv.remote.service
```

To restore any package:

```bash
adb shell pm install-existing --user 0 <package.name>
```

**Do not remove** GMS, Play Store, WebView, Bluetooth, TV launcher, `com.nvidia.ota` (unless rooted and intentionally blocking OTA), or any NVIDIA media stack package.

---

## Known issue: RemountJobService crash

The Shield's `com.nvidia.shield.nas` app contains a bug — `RemountJobService` calls `unbindService()` twice, triggering an `IllegalArgumentException: Service not registered` crash once per boot. This is harmless to function (the share comes up fine) but produces a noisy crash in logcat and prevents the job from rescheduling itself.

The crash looks like:

```
E AndroidRuntime: java.lang.IllegalArgumentException: Service not registered: ...
E AndroidRuntime:   at com.nvidia.shield.nas.RemountJobService$b.q(RemountJobService.java:29)
```

Fixing it requires root + Magisk + apktool to patch the smali. The mount watchdog in this repo is a non-root workaround that recovers from the resulting mount drops automatically.

---

## Tested on

- NVIDIA Shield TV (darcy), Android 11 (RQ1A.210105.003)
- Linux host running systemd, `adb` 34+, Docker Compose v2
