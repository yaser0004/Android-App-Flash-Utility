# Android System App Injector

Install any APK as a true system app on any Android 10+ device with an unlocked bootloader — no root required, no recovery needed.

Apps installed this way live on the `/product` partition. They survive factory resets, survive ROM updates (re-run the scripts after flashing a new ROM), and can be granted privileged permissions that normal user-installed apps cannot have.

---

## How it works

```
payload.bin ──[payload_dumper]──► input/product.img   (stock, never modified)
                                         │
                              inject_apps.sh
                              (reads from product/)
                                         │
                                         ▼
                               output/product.img      (modified, ready to flash)
                                         │
                              flash_product.sh
                                         │
                                         ▼
                                   YOUR PHONE
```

---

## Requirements

- Linux PC (Ubuntu/Debian/Mint or any distro)
- `adb` and `fastboot` — `sudo apt install android-tools-adb android-tools-fastboot`
- `python3`, `unzip` — `sudo apt install python3 unzip`
- `e2fsprogs` — `sudo apt install e2fsprogs`
- [`payload_dumper`](https://github.com/ssut/payload-dumper-go) — extracts partition images from ROM zips
- Android phone running **Android 10+** with an **unlocked bootloader** and a **custom ROM**

---

## Quick start

```bash
# 1. Drop your ROM zip (or payload.bin) into the payload_(or)_ROM-file/ folder, then:
bash extract_payload.sh     # extracts product.img → input/, vbmeta → output/

# 2. Disable AVB (do this once per device, phone must be in fastboot mode)
fastboot flash vbmeta_a   --disable-verity --disable-verification output/vbmeta.img
fastboot flash vbmeta_b   --disable-verity --disable-verification output/vbmeta.img

# 3. Put your APKs in the product/ folder
mkdir product/app/NewPipe
cp ~/Downloads/NewPipe.apk product/app/NewPipe/NewPipe.apk

# 4. Inject apps into the image
sudo bash inject_apps.sh

# 5. Flash to your phone (handles fastbootd, A/B slots, auto-reboot automatically)
bash flash_product.sh
```

Every run of `inject_apps.sh` starts fresh from `input/product.img`, so the result depends only on what is in `product/` — not on any prior run. Add an app, remove an app, update an app: just change `product/` and re-run.

---

## What's in this repo

```
extract_payload.sh          — STEP 1: drop ROM zip in payload_(or)_ROM-file/, run this to extract images
inject_apps.sh              — STEP 2: injects APKs into product.img (handles split APKs,
                              ABI filtering, native lib pre-extraction, auto partition grow)
flash_product.sh            — STEP 3: flashes product.img (handles fastbootd, A/B slots,
                              auto-reboot from Android mode)
payload_(or)_ROM-file/      — drop your ROM zip or payload.bin here
product/
  app/                      — regular system apps (put APK folders here)
  priv-app/                 — privileged system apps (app stores, VPNs, system tools)
ADB-Sideload_ZIP_Creator/   — alternative method using custom recovery + adb sideload
```

For the full setup walkthrough, troubleshooting, and detailed explanations: **[GUIDE.md](GUIDE.md)**

---

## Folder structure for your apps

```
product/
  app/
    NewPipe/
      NewPipe.apk
    Bitwarden/
      Bitwarden.apk
  priv-app/
    AuroraStore/
      AuroraStore.apk
    F-Droid/
      F-Droid.apk
```

For apps distributed as split APK bundles (`.apkm` from APKMirror), put all relevant splits in the folder — the script picks the right architecture automatically:

```
product/
  app/
    FirefoxFocus/
      base.apk
      split_config.arm64_v8a.apk
      split_config.xxhdpi.apk
```

---

## Tested on

- OnePlus Nord (AC2001) — Android 14, Project Infinity-X 3.11 (LineageOS-based)
- Should work on any Android 10+ device with dynamic partitions and an unlocked bootloader
