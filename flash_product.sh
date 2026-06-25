#!/usr/bin/env bash
# flash_product.sh — flash a modified product.img to the connected Android device
#
# USAGE:  bash flash_product.sh [OPTIONS]
#
# OPTIONS:
#   --img <path>        Path to image file (default: output/product.img)
#   --slot <a|b|both|auto>
#                       Which slot(s) to flash (default: auto — detects from device)
#   --dry-run           Print what would be flashed, without flashing
#   --no-auto-reboot    Do not automatically reboot device from Android/recovery
#                       into fastboot (useful for scripting or CI)
#
# This script handles all of the following automatically:
#   - Device in Android or recovery mode → reboots to bootloader via ADB
#   - Dynamic partitions (needs fastbootd) vs physical partitions (bootloader fastboot)
#   - A/B (two-slot) devices vs single-slot devices
#
# REQUIREMENTS:
#   - fastboot (and adb for auto-reboot) installed and in PATH
#   - Device connected via USB in any mode (Android, recovery, or fastboot)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="$HERE/output/product.img"
SLOT_OVERRIDE=""
DRY_RUN=0
AUTO_REBOOT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --img)             IMG="$2";           shift 2 ;;
    --slot)            SLOT_OVERRIDE="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1;          shift ;;
    --no-auto-reboot)  AUTO_REBOOT=0;      shift ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1  (use --help)" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "  $*"; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [DRY-RUN] $*"
  else
    echo "  Running: $*"
    "$@"
  fi
}

[ -f "$IMG" ] || die "Image not found: $IMG"
command -v fastboot >/dev/null 2>&1 || die "fastboot not found — install android-tools-fastboot (or platform-tools)"

echo ""
echo "========================================================"
echo "  flash_product.sh"
echo "  Image: $IMG ($(du -h "$IMG" | cut -f1))"
echo "========================================================"
echo ""

# ── auto-reboot from Android/recovery into fastboot if needed ─────────────────
if [ "$AUTO_REBOOT" = "1" ] && [ "$DRY_RUN" = "0" ]; then
  if ! fastboot devices 2>/dev/null | grep -q fastboot; then
    if command -v adb >/dev/null 2>&1 \
       && adb devices 2>/dev/null | grep -qE $'\t''(device|recovery|sideload)$'; then
      _mode="$(adb devices 2>/dev/null | grep -vE '^List|^$' | awk 'NR==1{print $2}')"
      echo "==> Device detected in ADB mode ($_mode) — rebooting to bootloader..."
      adb reboot bootloader
      echo "  Waiting for fastboot (up to 30 s)..."
      _waited=0
      until fastboot devices 2>/dev/null | grep -q fastboot; do
        sleep 2; _waited=$(( _waited + 2 ))
        [ "$_waited" -ge 30 ] && break
      done
    fi
  fi
fi

# ── wait for a fastboot device ────────────────────────────────────────────────
echo "==> Waiting for fastboot device (up to 60 s)..."
timeout 60 fastboot wait-for-device 2>/dev/null \
  || die "No fastboot device appeared after 60 seconds.
  Make sure the device is connected via USB, then either:
    In Android: plug in and retry (the script reboots it automatically)
    Already in fastboot: check 'fastboot devices' in a terminal
    Manually: hold Power + Volume Down while booting (varies by device)"
DEV="$(fastboot devices 2>/dev/null | head -n1 | awk '{print $1}')"
echo "  Device: $DEV"

# ── detect if we're in userspace fastboot (fastbootd) ────────────────────────
IS_USERSPACE="$(fastboot getvar is-userspace 2>&1 | grep '^is-userspace:' | awk '{print $2}' || true)"
echo "  is-userspace (fastbootd?): ${IS_USERSPACE:-no}"

# ── if not already in fastbootd, try switching ───────────────────────────────
# NOTE: 'is-logical:product' is only reliable from fastbootd, not bootloader
# fastboot. Strategy: for any A/B device, always prefer fastbootd — it handles
# both dynamic (logical) and physical partitions. For single-slot devices,
# bootloader fastboot is fine.
if [ "${IS_USERSPACE:-no}" != "yes" ]; then
  echo ""
  echo "==> Not in fastbootd — attempting to switch (needed for dynamic partitions)..."
  if [ "$DRY_RUN" != "1" ]; then
    fastboot reboot fastboot 2>/dev/null || true
    echo "  Waiting for fastbootd..."
    fastboot wait-for-device 2>/dev/null || true
    sleep 2
  fi
  IS_USERSPACE="$(fastboot getvar is-userspace 2>&1 | grep '^is-userspace:' | awk '{print $2}' || true)"
  if [ "${IS_USERSPACE:-no}" = "yes" ]; then
    echo "  Now in fastbootd."
  else
    echo "  Device does not support fastbootd — staying in bootloader fastboot."
    echo "  (This is normal for older Android devices with physical partitions.)"
  fi
fi

# ── detect A/B slots ──────────────────────────────────────────────────────────
SLOT_COUNT="$(fastboot getvar slot-count 2>&1 | grep '^slot-count:' | awk '{print $2}' || true)"
CURRENT_SLOT="$(fastboot getvar current-slot 2>&1 | grep '^current-slot:' | awk '{print $2}' || true)"
[ -z "$SLOT_COUNT" ] && SLOT_COUNT="1"

echo "  slot-count:    $SLOT_COUNT"
echo "  current-slot:  ${CURRENT_SLOT:-(single-slot)}"
echo ""

# ── determine what to flash ───────────────────────────────────────────────────
if [ -n "$SLOT_OVERRIDE" ]; then
  SLOTS_TO_FLASH="$SLOT_OVERRIDE"
elif [ "$SLOT_COUNT" = "2" ]; then
  SLOTS_TO_FLASH="both"
else
  SLOTS_TO_FLASH="single"
fi

echo "==> Flash plan:"
case "$SLOTS_TO_FLASH" in
  both)
    say "Will flash: product_a  AND  product_b  (A/B device — flashing both slots)"
    ;;
  a|b)
    say "Will flash: product_$SLOTS_TO_FLASH  (forced slot)"
    ;;
  single)
    say "Will flash: product  (single-slot device)"
    ;;
esac
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo "  [DRY-RUN mode — nothing will actually be flashed]"
  echo ""
fi

# ── flash ─────────────────────────────────────────────────────────────────────
echo "==> Flashing..."
case "$SLOTS_TO_FLASH" in
  both)
    run fastboot flash product_a "$IMG"
    run fastboot flash product_b "$IMG"
    ;;
  a|b)
    run fastboot flash "product_$SLOTS_TO_FLASH" "$IMG"
    ;;
  single)
    run fastboot flash product "$IMG"
    ;;
esac

echo ""
echo "==> Rebooting device..."
run fastboot reboot

echo ""
echo "========================================================"
echo "  Done! Device is rebooting."
echo "  First boot may take 2-5 minutes — Android is optimizing"
echo "  the newly installed system apps. This is normal."
echo "========================================================"
