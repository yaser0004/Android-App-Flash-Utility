# How to Install True System Apps on a Custom-ROM Android Device (Android 10+)
### A complete beginner-to-advanced guide

---

## What are we actually doing here?

When you install an app normally from the Play Store or a downloaded APK, Android puts it in `/data/app/`. Apps in that location:
- Get wiped if you factory reset
- Cannot be granted special "privileged" permissions
- Can be uninstalled by anyone

**System apps** live on a different storage partition — a read-only section of the phone's storage that Android reads at boot, before your personal data is even touched. They:
- Survive factory resets
- Survive ROM updates (re-apply this process after each ROM flash to get them back)
- Can be granted powerful "privileged" permissions — for example, an app store installed this way can silently install other apps without prompting, just like the Play Store does
- Cannot be removed without reversing this process

The partition we target is called `/product`. It was introduced in Android 10 as the dedicated home for manufacturer-added apps. On a custom ROM it's mostly empty, which means we have room to add our own. This approach works on Android 10 and later — tested on Android 16.

**The method:** We extract the stock `/product` partition image from the ROM's installer file, loop-mount the copy on our Linux PC like a regular folder, add our APKs directly into it, fix permissions, unmount it, then write it back to the phone using fastboot — the same low-level tool used by ROM developers themselves.

---

## Requirements

### Your Linux PC needs:
- **Ubuntu / Debian / Mint / any Linux distro** (this guide uses `apt`; adapt for your distro)
- **Python 3** — `sudo apt install python3`
- **ADB and Fastboot** — `sudo apt install android-tools-adb android-tools-fastboot`
  - Alternatively, download [Android Platform Tools](https://developer.android.com/tools/releases/platform-tools) directly from Google and add to PATH
- **unzip** — `sudo apt install unzip`
- **e2fsprogs** (provides `resize2fs` and `e2fsck`) — `sudo apt install e2fsprogs`
- **[payload_dumper](https://github.com/rhythmcache/payload-dumper-rust)** — extracts partition images from ROM zip files; `extract_payload.sh` finds it automatically if installed, or attempts to install it via pip if not
- **sudo access** — the injection step loop-mounts an ext4 image, which requires root

---

### Your Android phone — required conditions (ALL must be true)

> **These scripts do not unlock your bootloader or install a custom ROM for you. Every condition below must already be met before you run anything here.**

**1. Bootloader is unlocked**
The bootloader must be unlocked — this is a one-time hardware-level step done in fastboot mode, before flashing any custom software. On most devices: enable *OEM unlocking* in Developer Options, then run `fastboot flashing unlock`. This **wipes all data on the device**. Look up the exact unlock procedure for your specific device model before attempting — the steps vary.

Not all devices support bootloader unlocking:
- Many carrier-branded devices (especially US Verizon/AT&T variants) are permanently locked at the hardware level
- Most Huawei/Honor devices lost official unlock support in 2018
- Some manufacturers (e.g., Xiaomi) require approval through a vendor account and a mandatory waiting period

If your device cannot have its bootloader unlocked, these scripts **will not work**.

**2. A custom ROM is installed**
Stock/official OEM ROMs cryptographically sign every partition using Android Verified Boot (AVB). Even after disabling AVB in fastboot, a stock ROM may still refuse to boot from a modified partition, or it may silently re-enable verification on the next boot. A custom ROM (LineageOS, crDroid, PixelOS, Project Infinity-X, etc.) is required for reliable operation.

**3. Dynamic (logical) partitions with A/B slots**
The `/product` partition must be a *logical* partition inside Android's dynamic partition system, and the device must use A/B (seamless) updates. This is standard on devices that launched with Android 10 or later. Devices that originally shipped on Android 9 or earlier, or A-only (single-slot) devices, may have a different layout and are untested with these scripts.

**4. USB debugging enabled and ADB authorized**
`flash_product.sh` can reboot your device from Android into fastboot automatically over USB. For this to work, *USB debugging* must be enabled in Developer Options and the connected PC must already be authorized — meaning you have accepted the "Allow USB debugging?" prompt on the phone at least once for this PC. If you prefer to reboot to fastboot manually instead, pass `--no-auto-reboot` to the flash script.

> **How to check your Android version:** Settings → About Phone → Android version

---

## How the scripts work together

```
YOUR ROM ZIP
    │
    │  bash extract_payload.sh
    ▼
input/product.img ─────────────────────────── (stock, NEVER modified)
    │                                                   │
    │  sudo bash inject_apps.sh                         │ permanent clean baseline
    │  (reads APKs from product/ folder)                │
    ▼
output/product.img ── bash flash_product.sh ──► YOUR PHONE ✓
                                               (/product partition now has
                                                your apps as true system apps)

extract_payload.sh also writes:
output/vbmeta.img       ── flash once (Step 2) ──► disables Android Verified Boot
output/vbmeta_system.img   (if present in ROM)
```

**Key design:** `input/product.img` is your permanent stock baseline — no script ever modifies it. Every run of `inject_apps.sh` copies it fresh to `output/product.img`, then injects your apps into the copy. This means:
- Re-running always produces a clean, predictable result based solely on the current contents of `product/`
- Removing an app's folder from `product/` removes it from the next output
- You never need to re-extract from the ROM just to start fresh

---

## The files and folders in this directory

```
FLASHING/
│
├── README.md                     ← project overview
├── GUIDE.md                      ← you are here
│
├── extract_payload.sh            ← STEP 1: extract images from ROM zip
├── inject_apps.sh                ← STEP 2: inject APKs into product.img
├── flash_product.sh              ← STEP 3: flash product.img to your phone
│
├── payload_(or)_ROM-file/        ← drop your ROM zip or payload.bin here
│
├── product/                      ← YOUR APK SOURCE TREE (edit this freely)
│   ├── app/                      ← regular system apps go here
│   │   └── <AppName>/
│   │       └── <AppName>.apk
│   └── priv-app/                 ← privileged system apps go here
│       └── <AppName>/
│           └── <AppName>.apk
│
├── input/                        ← stock image extracted from ROM (never modified)
│   └── product.img
│
├── output/                       ← generated files (recreated every inject run)
│
└── Logs/                         ← one log file per script run (gitignored)
    ├── product.img               ← modified partition image, ready to flash
    ├── vbmeta.img                ← extracted from ROM (flash once to disable AVB)
    └── vbmeta_system.img         ← same (only present if the ROM includes it)
```

---

## PART 1 — First-time setup for a new device

Do this entire Part once per device. When you just want to update an app later, skip to Part 2.

---

### Step 0 — Get your ROM file

Custom ROMs are distributed as `.zip` files. You can find them on the ROM's official thread (usually on [XDA Developers](https://xda-developers.com)) or the ROM developer's release page. Download the full OTA zip — not an incremental update zip, and not just the `payload.bin` — the full ROM zip.

Place the downloaded zip directly in the `payload_(or)_ROM-file/` folder:

```bash
cp ~/Downloads/your-rom-filename.zip /path/to/FLASHING/payload_(or)_ROM-file/
```

That's all — you don't need to open the zip or locate `payload.bin` inside it. The extraction script reads it directly.

> **If you already have a raw `payload.bin`** (extracted separately), place it in `payload_(or)_ROM-file/payload.bin` — the script detects either format automatically.

---

### Step 1 — Extract partition images

```bash
cd /path/to/FLASHING/
bash extract_payload.sh
```

The script does the following automatically:
1. Finds your ROM zip (or `payload.bin`) in `payload_(or)_ROM-file/`
2. Locates `payload_dumper` on your system, or installs it if not found
3. Extracts `product.img` → `input/` (the stock baseline every inject run starts from)
4. Extracts `vbmeta.img` and `vbmeta_system.img` → `output/` (used in Step 2 to disable AVB)
5. Prints a summary with the exact fastboot commands to run in Step 2

> **What is payload.bin?** Modern Android OTA packages store every partition as a binary stream inside a single file called `payload.bin`, which lives inside the ROM zip. `payload_dumper` understands this format and can extract individual partitions directly from the zip without fully unzipping it first.

---

### Step 2 — Disable Android Verified Boot (one time per device)

Android Verified Boot (AVB) cryptographically signs every partition so the phone can detect if they have been tampered with. Because we are deliberately modifying `product`, we need to disable this check — otherwise the phone will refuse to boot after we flash our image.

> **This step is done once per device.** AVB stays disabled across normal reboots and even ROM updates, as long as you keep the patched vbmeta. You only need to redo this if you re-flash stock vbmeta images.

**Boot into fastboot mode** (do one of these):
```bash
adb reboot bootloader
```
Or hold the hardware key combination for your device (commonly Power + Volume Down — look it up for your specific model). Your screen will show a fastboot/bootloader menu — it will NOT look like a normal Android screen.

**Confirm the PC sees the device:**
```bash
fastboot devices
# Should print something like:  abae8b16    fastboot
# If it prints nothing, check your USB cable and that the driver is installed
```

**Flash the patched vbmeta images** — use the exact commands printed at the end of `bash extract_payload.sh`. They will look like this:
```bash
# Always required — flash both A and B slots:
fastboot flash vbmeta_a   --disable-verity --disable-verification output/vbmeta.img
fastboot flash vbmeta_b   --disable-verity --disable-verification output/vbmeta.img

# Only if output/vbmeta_system.img exists (extract_payload.sh will tell you):
fastboot flash vbmeta_system_a   --disable-verity --disable-verification output/vbmeta_system.img
fastboot flash vbmeta_system_b   --disable-verity --disable-verification output/vbmeta_system.img
```

**Reboot and verify the phone still boots normally:**
```bash
fastboot reboot
```
Wait for Android to fully boot (first boot after AVB disable may show an "orange state" warning for a few seconds — this is normal on custom ROMs). If the phone boots, AVB is successfully disabled.

> **Why `_a` and `_b`?** A/B devices keep two full copies of every partition so Android can update one slot while booting from the other. Both must be patched, otherwise the phone may switch to the unpatched slot and boot with AVB still active.

> **Why does `--disable-verity` come before the filename?** It is a fastboot quirk — these flags must appear before the image path, otherwise fastboot silently ignores them and flashes without disabling anything.

---

### Step 3 — Add your apps to the `product/` folder

The `product/` folder is your APK source tree. Whatever is in here gets injected into the partition image on the next run of `inject_apps.sh`. You can add, remove, and update freely — just run inject + flash again after any change.

---

**`app/` vs `priv-app/` — which to use:**

| Use `app/` for | Use `priv-app/` for |
|----------------|---------------------|
| Any regular app you want pre-installed | App stores that need to install other apps silently |
| Media players, browsers, utilities | VPN clients that need always-on VPN permission |
| File managers, productivity tools | Audio processing apps that need system audio access |
| Anything that works fine as a normal install | Any app that specifically requires privileged system permissions |

When in doubt, use `app/`. The only difference is that `priv-app/` apps can request a set of privileged permissions that Android reserves for system components — if an app doesn't need those, `app/` is the correct location.

---

**Single APK — the common case:**

Each app gets its own subfolder. The folder name and the APK filename can be anything — use the app's name for clarity:

```bash
mkdir product/app/<AppName>
cp ~/Downloads/<AppName>.apk product/app/<AppName>/<AppName>.apk
```

Example structure:
```
product/
  app/
    <AppName>/
      <AppName>.apk
  priv-app/
    <AppName>/
      <AppName>.apk
```

---

**Split APK bundle (`.apkm` from APKMirror):**

Some apps are distributed as split APKs — a bundle of multiple `.apk` files where each file contains a subset of the app (base code, architecture-specific native libraries, screen density resources, language packs). The `.apkm` format from APKMirror is just a renamed zip containing these splits.

```bash
# Rename .apkm to .zip and extract it
cp ~/Downloads/app.apkm /tmp/app.zip
unzip /tmp/app.zip -d /tmp/app/

# See what's inside
ls /tmp/app/
# base.apk                      ← always needed
# split_config.arm64_v8a.apk    ← native libs for ARM64
# split_config.x86_64.apk       ← native libs for x86_64 (skip on ARM phones)
# split_config.xxhdpi.apk       ← graphics for your screen density
# split_config.en.apk           ← English language pack

# Copy them into a product/ subfolder
mkdir product/app/<AppName>
cp /tmp/app/*.apk product/app/<AppName>/
```

You can safely copy all `.apk` files — `inject_apps.sh` automatically skips architecture splits that don't match your device (e.g., it will skip `split_config.x86_64.apk` on an ARM phone). You do not need to manually pick the right architecture split.

The only splits you might want to leave out are **language packs** you don't need (`split_config.fr.apk`, `split_config.de.apk`, etc.) to save partition space — but this is optional.

---

**Updating an existing app:**
```bash
cp ~/Downloads/<AppName>-new-version.apk product/app/<AppName>/<AppName>.apk
# Then re-run inject + flash (Part 2)
```

**Removing an app from the system:**
```bash
rm -rf product/app/<AppName>
# The next inject run will not include it
```

---

### Step 4 — Inject the apps into the partition image

Connect your phone via USB before running this step — the script will detect your device's CPU architecture automatically. If your phone is not connected, it defaults to `arm64-v8a armeabi-v7a armeabi`, which is correct for most modern phones.

```bash
sudo bash inject_apps.sh
```

The script does all of this in order:
1. Detects your device's CPU ABI list via `adb shell getprop ro.product.cpu.abilist`
2. Validates `input/product.img` is a real ext4 filesystem before touching it
3. Copies `input/product.img` → `output/product.img` (every run starts fresh)
4. Mounts `output/product.img` read-only and calculates how much space the new apps require
5. Grows the partition image if needed (see Part 5)
6. Remounts read-write and injects every app folder from `product/`
7. For each APK, pre-extracts native `.so` libraries alongside it (required because `/product` is read-only at runtime — Android cannot extract them itself)
8. Sets correct ownership (`root:root`), permissions (`0755` dirs / `0644` files), and SELinux labels (`u:object_r:system_file:s0`) on everything injected
9. Unmounts cleanly and saves a log to `Logs/`

**Safety:** If anything goes wrong mid-injection (out of space, tool error, Ctrl+C), the script removes the incomplete `output/product.img` automatically so you can never accidentally flash a half-injected image.

You'll see output like this:
```
  Log: /path/to/FLASHING/Logs/Logs_30-06-2026_14:30:00.txt
  ABI detected from connected device: arm64-v8a armeabi-v7a armeabi

==> Preparing output image...
  Copying 1.2G  input/product.img → output/product.img
  Done.

==> Checking space requirements...
  Net new data needed : 450 MB
  Free space in image : 580 MB
  Sufficient space (580 MB free, need 450 MB + 80 MB buffer) — no resize needed

Mounted output/product.img → /mnt/product_edit

==> Injecting app/
  + app/<AppName>  (none)
  + app/<AppName>  (arm64-v8a) [split: 3 APKs]
      extracted native libs → lib/
  SKIP (ABI x86_64 not in {arm64-v8a ...}): <AppName>

==> Injecting priv-app/
  + priv-app/<AppName>  (none)

==> Done. Unmounted cleanly.
    Installed : 3 apps
    Skipped   : 1 apps (ABI-incompatible)
    Log saved : Logs/Logs_30-06-2026_14:30:00.txt
```

**What `(none)` means for ABI:** The APK contains no native code — it is pure Java/Kotlin and runs on any CPU. This is fine.

**What `SKIP (ABI)` means:** The APK (or this specific split) contains native code compiled only for a CPU architecture your device does not have. An x86-only app would crash immediately on an ARM phone. Either get a universal build of the app, or get the arm64 build specifically.

**What `[split: N APKs]` means:** Multiple APK files were found in the folder and all compatible ones were injected together as a split bundle.

**If the partition needs to grow:** The script handles this automatically — see Part 5 for details.

---

### Step 5 — Flash the image to your phone

```bash
bash flash_product.sh
```

This script handles everything:

1. **Auto-reboot to fastboot** — If your phone is running Android, the script reboots it to the bootloader automatically via ADB. If already in fastboot, it skips this.
2. **Switch to fastbootd** — Standard bootloader fastboot cannot flash logical (dynamic) partitions like `/product`. The script reboots into *fastbootd* (Android's userspace fastboot implementation, which can address logical partitions) before flashing. If your device does not support fastbootd, it stays in bootloader fastboot — this means your device likely uses physical partitions and is still compatible.
3. **Detect A/B slots** — The script reads `slot-count` from the device and flashes both `product_a` and `product_b` on A/B devices, or just `product` on single-slot devices.
4. **Flash and reboot** — Writes `output/product.img` to the appropriate partition(s) and reboots the device.

**First boot is slow — this is completely normal.** Android dex-optimizes (compiles to machine code) every new system app during first boot. The more apps you added, the longer this takes. Expect 2–5 minutes, sometimes more on older hardware. The boot animation will loop repeatedly — let it finish on its own.

---

## PART 2 — Adding, updating, or removing an app

After first-time setup, this is the entire workflow for any subsequent change:

```bash
# Add a new app or update an existing one:
cp ~/Downloads/<AppName>.apk product/app/<AppName>/<AppName>.apk

# Remove an app:
rm -rf product/app/<AppName>

# Re-inject and flash:
sudo bash inject_apps.sh
bash flash_product.sh
```

Because `inject_apps.sh` always starts from a fresh copy of `input/product.img`, the output image reflects exactly and only what is currently in `product/`. Removing a folder removes that app from the next flash — no manual cleanup of the image needed.

---

## PART 3 — After a ROM update

When you flash a new ROM version, the `/product` partition is overwritten with the ROM's stock version. Your apps are gone from the device, but your `product/` folder is untouched — all your APKs are still there.

```bash
# 1. Drop the new ROM zip into payload_(or)_ROM-file/ (replacing the old one)
cp ~/Downloads/new-rom.zip /path/to/FLASHING/payload_(or)_ROM-file/

# 2. Re-extract (overwrites input/product.img with the new ROM's stock version,
#    and writes fresh vbmeta images to output/)
bash extract_payload.sh

# 3. Re-patch vbmeta — boot phone into fastboot first, then:
fastboot flash vbmeta_a   --disable-verity --disable-verification output/vbmeta.img
fastboot flash vbmeta_b   --disable-verity --disable-verification output/vbmeta.img
# (also vbmeta_system_a/b if applicable — extract_payload.sh will say)

# 4. Re-inject (product/ folder is untouched — all your APKs are still there)
sudo bash inject_apps.sh

# 5. Flash
bash flash_product.sh
```

> **Why re-patch vbmeta on every ROM update?** Flashing a new ROM restores the stock signed vbmeta, re-enabling AVB. You must disable it again with the new ROM's vbmeta images each time.

---

## PART 4 — Using this on a different device

Almost everything works identically on any supported Android device with an unlocked bootloader.

**1. Get that device's ROM zip** — drop it in `payload_(or)_ROM-file/` and run `bash extract_payload.sh`, same as the first-time setup.

**2. Run the same Steps 1–5** — the scripts auto-detect everything: CPU ABI, slot count, whether fastbootd is needed.

**3. Potential gotcha — no `/product` partition (Android 9 or earlier):**
Android 10 introduced `/product`. Devices running Android 9 or earlier put OEM apps in `/system/app/` instead. These scripts only target `/product` — they will not work on pre-10 devices without significant modification.

**4. Potential gotcha — `vbmeta_system` doesn't exist:**
Not all devices or ROMs have a `vbmeta_system` partition. `extract_payload.sh` handles this gracefully and simply won't produce `output/vbmeta_system.img`. Skip the `vbmeta_system_a/b` flash commands in that case.

---

## PART 5 — Partition growth (handled automatically)

The stock `/product` image has a fixed size baked into the ROM. If the apps you want to inject are larger than the available free space in that image, the injection would fail with "no space left on device."

The script detects this before it happens and grows the image automatically. **You do not need to do anything manually.**

**What the script does:**
1. Pre-scans all app folders and calculates the total net new bytes needed (accounting for apps already in the image)
2. Adds an 80 MB safety buffer
3. If that total exceeds available free space — or if the image is already 100% full (common with GAPPS ROMs that ship with Google apps pre-installed) — runs `truncate` (extends the file), then `e2fsck -f -p` (repairs filesystem metadata), then `resize2fs` (expands the filesystem to fill the new size). Any tool failure here is fatal — the script will not proceed with a partially grown image.
4. When you flash with `flash_product.sh`, fastbootd resizes the on-device logical partition to match the new image size automatically

You'll see:
```
==> Auto-growing image by 128 MB (host has 45G free)...
  Image is now 1.6G
```

**GAPPS ROMs:** If you are using a ROM that ships with Google apps (the `product` partition is 100% full out of the box), the script will still grow the image correctly — it treats a genuinely-full filesystem the same as any other space deficit.

**Why this works at the device level:**
`/product` is a *logical* partition living inside a larger block device called `super`. Logical partitions can be dynamically resized up to however much unallocated space remains in `super`. The ceiling varies by device — run `fastboot getvar partition-size:super` to see the total super size. If you exceed available headroom, the flash will fail with a resize error (the device is still safe; just re-flash the stock ROM).

**Incremental builds:**
To build on top of a previous output (instead of always starting from the stock baseline), copy the output image back to input before running inject again:
```bash
cp output/product.img input/product.img
```
The next inject run will start from this modified baseline. Useful if you want to layer changes incrementally rather than re-injecting everything from scratch each time.

---

## Troubleshooting

**`inject_apps.sh`: "Input image not found: input/product.img"**
`product.img` hasn't been extracted yet. Place your ROM zip in `payload_(or)_ROM-file/` and run:
```bash
bash extract_payload.sh
```

**"mount: /mnt/product_edit: can't read superblock"**
The image file is corrupt or truncated (possibly from an interrupted extraction). Re-extract a clean copy:
```bash
bash extract_payload.sh
```

**"inject_apps.sh: pre-scan mount failed — is the image already mounted?"**
A previous run of `inject_apps.sh` crashed and the loop mount was not released. Unmount manually:
```bash
sudo umount /mnt/product_edit
```
Then re-run. This should be rare — the script installs an EXIT trap to unmount automatically on failure.

**`fastboot devices` returns nothing**
- Try a different USB cable (data cables, not charge-only)
- Try a different USB port (USB 2.0 ports are sometimes more reliable for fastboot than USB 3.0)
- On Linux: you may need udev rules — run `sudo apt install android-sdk-platform-tools-common` or add a udev rule manually for your device's vendor ID
- Confirm the phone screen actually shows a fastboot/bootloader menu (not just a black screen)

**"fastboot: Partition not found" when flashing manually**
You are in bootloader fastboot but your device uses dynamic partitions. Logical partitions like `product_a` only exist from fastbootd, not from bootloader fastboot. Switch:
```bash
fastboot reboot fastboot    # reboots into fastbootd (userspace fastboot)
fastboot flash product_a output/product.img
```
Or just use `bash flash_product.sh` — it handles the fastbootd switch automatically.

**"FAILED (remote: 'This partition doesn't exist')" for vbmeta_system**
Your device or ROM does not have a `vbmeta_system` partition. Skip those two commands — only flash `vbmeta_a` and `vbmeta_b`.

**Apps crash immediately on open**
Two likely causes:
1. **Missing architecture split** — the app is a split bundle and you copied only `base.apk` without the architecture-specific split (e.g., `split_config.arm64_v8a.apk`). Add the missing split to the app's folder in `product/` and re-inject.
2. **ABI mismatch** — the APK's native code is compiled only for an architecture your device doesn't have (e.g., x86-only on an ARM phone). Get a universal or arm64 build of the app.

**Phone bootloops after flashing**
First: did `flash_product.sh` report success? If `inject_apps.sh` failed or was interrupted, it removes the incomplete output image automatically — `flash_product.sh` will then refuse to run with "Image not found". If that happened, just re-run inject and try again; there is no bad image on the device.

If `flash_product.sh` did succeed but the phone bootloops, the image was injected but contains something the device rejects. Re-extract a clean baseline and re-inject, removing whichever app was likely the cause:
```bash
bash extract_payload.sh
# Remove the suspected APK from product/ first, then:
sudo bash inject_apps.sh
bash flash_product.sh
```
If it still bootloops after removing all injected apps, boot into recovery and do a factory reset, then re-flash the ROM cleanly.

**First boot takes longer than 10 minutes**
Give it up to 15 minutes on slower devices or if you injected many large apps. If it truly never finishes, hold Power for 10 seconds to force reboot — Android will typically boot normally on the second attempt, having already optimized most apps during the first failed attempt.

**Apps show as "not installed" or conflict with an existing user-installed version**
If a user-installed version of the same app (with a different signing key) exists on the device, Android will see a signature conflict and may not recognize the system version. Uninstall the user version first:
```bash
adb shell pm uninstall com.example.apppackagename
```
Then reboot — the system version will take over.

---

## Quick reference card

```bash
# ── ONE-TIME SETUP PER DEVICE ────────────────────────────────────────────────

# Drop ROM zip (or payload.bin) into payload_(or)_ROM-file/, then:
bash extract_payload.sh     # extracts product.img → input/, vbmeta → output/

# Disable AVB — phone must be in fastboot mode (use exact commands from script output)
fastboot flash vbmeta_a   --disable-verity --disable-verification output/vbmeta.img
fastboot flash vbmeta_b   --disable-verity --disable-verification output/vbmeta.img
# Only if vbmeta_system.img was extracted:
fastboot flash vbmeta_system_a   --disable-verity --disable-verification output/vbmeta_system.img
fastboot flash vbmeta_system_b   --disable-verity --disable-verification output/vbmeta_system.img
fastboot reboot

# ── MANAGE YOUR APPS (edit product/ freely) ──────────────────────────────────

# Add a single APK:
mkdir product/app/<AppName>
cp <AppName>.apk product/app/<AppName>/<AppName>.apk

# Add a split APK bundle (.apkm from APKMirror):
unzip app.apkm -d /tmp/app/
mkdir product/app/<AppName>
cp /tmp/app/*.apk product/app/<AppName>/
# All splits are safe to copy — script auto-skips incompatible architecture splits

# Update:  cp new-version.apk product/app/<AppName>/<AppName>.apk
# Remove:  rm -rf product/app/<AppName>

# ── INJECT + FLASH ───────────────────────────────────────────────────────────

sudo bash inject_apps.sh    # fresh copy of input/ + inject product/ → output/
bash flash_product.sh       # auto-reboots phone, switches to fastbootd, flashes A+B

# ── AFTER A ROM UPDATE ───────────────────────────────────────────────────────

cp ~/Downloads/new-rom.zip /path/to/FLASHING/payload_(or)_ROM-file/
bash extract_payload.sh     # re-extracts new ROM's stock product.img and vbmeta

# Re-patch vbmeta (same fastboot commands as one-time setup above)

sudo bash inject_apps.sh    # product/ folder is untouched — all APKs still there
bash flash_product.sh
```
