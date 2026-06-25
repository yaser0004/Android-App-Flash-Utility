# Android System App Injector

> [!CAUTION]
> **This toolchain operates at the bootloader level — proceed with care.**
> Flashing a corrupted or incompatible image can prevent your device from booting. The scripts flash **both A/B slots**, so there is no automatic fallback if something goes wrong. Always keep a copy of your stock ROM and know how to enter EDL/download mode on your device before you start. You are solely responsible for any outcome.

Install any APK as a true system app on a custom-ROM Android device — no root required, no recovery needed. Apps live on the `/product` partition: they survive factory resets, survive ROM updates (just re-run the scripts after flashing a new ROM), and can hold privileged permissions unavailable to user-installed apps.

---

## How it works

```
ROM zip ──[extract_payload.sh]──► input/product.img   (stock, never modified)
                                          │
                               inject_apps.sh
                               (reads from product/)
                                          │
                                          ▼
                                output/product.img     (modified, ready to flash)
                                          │
                               flash_product.sh
                                          │
                                          ▼
                                    YOUR PHONE
```

`inject_apps.sh` always starts from a fresh copy of `input/product.img`, so the result reflects exactly and only what is in `product/`. Add, remove, or update an app — just edit `product/` and re-run inject + flash.

---

## Requirements

### Linux PC

```bash
# ADB and fastboot
sudo apt install android-tools-adb android-tools-fastboot

# Python, unzip, ext4 tools
sudo apt install python3 unzip e2fsprogs
```

**[payload_dumper](https://github.com/rhythmcache/payload-dumper-rust)** — fast Rust-based OTA extractor. `extract_payload.sh` locates it automatically if already installed, or attempts to install it via pip if not.

---

### Android device — required conditions (all must be true)

> [!IMPORTANT]
> These scripts do **not** unlock your bootloader or install a custom ROM for you. All of the conditions below must already be met before you run anything here.

**1. Bootloader is unlocked**
The bootloader must be unlocked — this is a one-time hardware-level step done in fastboot mode *before* flashing any custom software. On most devices: enable *OEM unlocking* in Developer Options, then run `fastboot flashing unlock`. This **wipes the device**. If you have not done this yet, look up the unlock procedure for your specific device model.

Not all devices can have their bootloader unlocked:
- Many carrier-branded devices (especially US Verizon/AT&T variants) are permanently locked
- Most Huawei/Honor devices lost unlock support in 2018
- Some OEM devices require a manufacturer account/token to unlock

If your device cannot have its bootloader unlocked, these scripts **will not work**.

**2. A custom ROM is installed**
Stock/official OEM ROMs cryptographically verify every partition at boot using Android Verified Boot (AVB). Even with AVB disabled in fastboot, a stock ROM may still refuse to boot from a modified partition or may re-lock the bootloader on its own. A custom ROM (LineageOS, crDroid, PixelOS, Project Infinity-X, etc.) is required for this to work reliably.

**3. Dynamic (logical) partitions**
The `product` partition must be a *logical* partition managed by the Android logical partition system. This is standard on devices that launched with Android 10 or later using A/B (seamless) updates. Devices that originally launched on Android 9 or earlier, or single-slot (A-only) devices, may have a different partition layout and are untested.

**4. USB debugging and ADB access**
`flash_product.sh` can auto-reboot your device from Android into fastboot mode over ADB. For this to work, USB debugging must be enabled in Developer Options and the PC must be authorized (accepted the ADB prompt on the phone). If you prefer to reboot manually, use `--no-auto-reboot`.

---

## Quick start


#### 1. Drop your ROM zip (or a raw payload.bin) into payload_(or)_ROM-file/, then:
```bash
bash extract_payload.sh
```
####    → writes input/product.img  (stock baseline)
####    → writes output/vbmeta*.img (for the AVB step below)

#### 2. Disable Android Verified Boot — ONE TIME per device
(phone must be in fastboot mode; exact commands are printed by extract_payload.sh)
```bash
fastboot flash vbmeta_a   --disable-verity --disable-verification output/vbmeta.img
fastboot flash vbmeta_b   --disable-verity --disable-verification output/vbmeta.img
```
also flash vbmeta_system_a/b if your ROM has them (the script tells you)

#### 3. Add your APKs to product/
```bash
mkdir -p product/app/<App_Name>
cp ~/Downloads/<App_Name>.apk product/app/<App_Name>/<App_Name>.apk
```
#### 4. Inject into the image (requires root for loop-mounting ext4)
```bash
sudo bash inject_apps.sh
```
#### 5. Flash to phone — auto-detects fastbootd, A/B slots, reboots device
```bash
bash flash_product.sh
```

---

## App folder layout

**Single APK:**
```
product/
  app/
    <App_Name>/
      <App_Name>.apk
  priv-app/
    <Priviliged_App_Name>/
      <Privileged_App_Name>.apk
```

**Split APK bundle** (`.apkm` from APKMirror — put all splits(ONLY FILES THAT END WITH .apk) in one folder, the script picks the right architecture and skips incompatible ones automatically):
```
product/
  app/
    <App_Name>/
      base.apk
      split_config.arm64_v8a.apk
      split_config.xxhdpi.apk
```

Use `priv-app/` for apps that need privileged system permissions (app stores, VPN clients, device management tools). Use `app/` for everything else.

---

## What's in this repo

```
extract_payload.sh          — STEP 1: extract product.img + vbmeta from ROM zip
inject_apps.sh              — STEP 2: inject APKs, fix permissions + SELinux xattrs,
                              pre-extract native libs, auto-grow partition if needed
flash_product.sh            — STEP 3: flash to device (handles fastbootd, A/B slots,
                              auto-reboot from Android/recovery mode)
payload_(or)_ROM-file/      — place your ROM zip or payload.bin here
product/
  app/                      — regular system apps
  priv-app/                 — privileged system apps
```

For the full setup walkthrough, troubleshooting, and detailed explanations: **[GUIDE.md](GUIDE.md)**

---

## Tested on

- **OnePlus Nord (AC2001)** — Android 16, Project Infinity-X 3.11 (based on Android Open Source Project (AOSP))
- Expected to work on any Android device with dynamic partitions, an unlocked bootloader, and a custom ROM (Android 10+)
