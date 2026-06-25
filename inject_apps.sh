#!/usr/bin/env bash
# inject_apps.sh — copy stock image, inject APKs, fix perms + SELinux, write output
#
# USAGE:  sudo bash inject_apps.sh [OPTIONS]
#
# OPTIONS:
#   --input <path>     Stock base image to start from (default: input/product.img)
#   --out   <path>     Where to write the modified image (default: output/product.img)
#   --src   <path>     Path to the product/ source tree (default: ./product)
#   --mnt   <path>     Mount point to use (default: /mnt/product_edit)
#   --abis  <list>     Override ABI list, space-separated
#                      e.g. --abis "arm64-v8a armeabi-v7a"
#                      (auto-detected from connected ADB device if omitted)
#
# ENVIRONMENT (alternative to flags):
#   DEV_ABIS="arm64-v8a armeabi-v7a armeabi"  sudo bash inject_apps.sh
#
# Every run starts fresh: input/product.img is copied to output/product.img,
# then the copy is modified. input/product.img is never touched.
# To do incremental builds on top of a previous output, copy the output back:
#   cp output/product.img input/product.img
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# ── defaults (overridable via flags) ─────────────────────────────────────────
INPUT_IMG="$HERE/input/product.img"
OUTPUT_IMG="$HERE/output/product.img"
MNT="/mnt/product_edit"
PRODUCT_SRC="$HERE/product"
DEV_ABIS="${DEV_ABIS:-}"

# ── parse flags ──────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --input) INPUT_IMG="$2";   shift 2 ;;
    --out)   OUTPUT_IMG="$2";  shift 2 ;;
    --src)   PRODUCT_SRC="$2"; shift 2 ;;
    --mnt)   MNT="$2";         shift 2 ;;
    --abis)  DEV_ABIS="$2";    shift 2 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1  (use --help)" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "  $*"; }

[ -f "$INPUT_IMG" ]   || die "Input image not found: $INPUT_IMG
  Run:  bash extract_payload.sh   (place your ROM zip in payload/ first)"
[ -d "$PRODUCT_SRC" ] || die "Source dir not found: $PRODUCT_SRC"
command -v python3   >/dev/null 2>&1 || die "python3 required  (sudo apt install python3)"
command -v unzip     >/dev/null 2>&1 || die "unzip required    (sudo apt install unzip)"
command -v resize2fs >/dev/null 2>&1 || die "resize2fs required (sudo apt install e2fsprogs)"

# ── auto-detect ABI from connected ADB device ────────────────────────────────
if [ -z "$DEV_ABIS" ]; then
  if command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | grep -q "device$"; then
    _abi="$(adb shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r' | tr ',' ' ')"
    [ -z "$_abi" ] && _abi="$(adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
    if [ -n "$_abi" ]; then
      DEV_ABIS="$_abi"
      say "ABI detected from connected device: $DEV_ABIS"
    fi
  fi
fi
if [ -z "$DEV_ABIS" ]; then
  DEV_ABIS="arm64-v8a armeabi-v7a armeabi"
  say "No ADB device detected — using default ABIs: $DEV_ABIS"
  say "(Override: --abis \"list\" or DEV_ABIS=... sudo bash inject_apps.sh)"
fi
echo ""

# ── copy stock image → output (fresh start every run) ────────────────────────
echo "==> Preparing output image..."
mkdir -p "$(dirname "$OUTPUT_IMG")"
say "Copying $(du -h "$INPUT_IMG" | cut -f1)  $INPUT_IMG → $OUTPUT_IMG"
cp --sparse=always "$INPUT_IMG" "$OUTPUT_IMG"
say "Done."
echo ""

# ── helpers ───────────────────────────────────────────────────────────────────

# Extract the comma-list of native ABIs from a single APK (or "none" if pure Java)
apk_abis() {
  local apk="$1" abis
  abis="$(unzip -l "$apk" 2>/dev/null | grep -oE 'lib/[^/]+/' | sed 's|lib/||;s|/||' | sort -u | paste -sd, - || true)"
  [ -z "$abis" ] && abis="none"
  printf '%s' "$abis"
}

# Detect the ABIs represented by all APKs in a folder.
# Handles both single APKs and split APK bundles (APKM/APKS).
# Checks ABI hints in split filenames first (fast), then APK internals.
folder_abis() {
  local dir="$1" apk bname abis
  for apk in "$dir"*.apk; do
    [ -f "$apk" ] || continue
    bname="$(basename "$apk")"
    # split_config.<abi>.apk filenames are definitive ABI indicators
    case "$bname" in
      *arm64_v8a*|*arm64-v8a*) printf 'arm64-v8a';   return ;;
      *armeabi_v7a*|*armeabi-v7a*) printf 'armeabi-v7a'; return ;;
      *x86_64*)                 printf 'x86_64';     return ;;
      *x86*)                    printf 'x86';        return ;;
      *armeabi*)                printf 'armeabi';    return ;;
    esac
    # fallback: inspect the APK's lib/ entries
    abis="$(apk_abis "$apk")"
    [ "$abis" != "none" ] && { printf '%s' "$abis"; return; }
  done
  printf 'none'  # no native code found — pure Java, always compatible
}

# If a filename is an architecture split (split_config.<abi>.apk), return that ABI.
# Returns "none" for base.apk, density splits, language splits, and regular APKs.
split_abi_from_name() {
  case "$1" in
    *arm64_v8a*|*arm64-v8a*) printf 'arm64-v8a'   ;;
    *armeabi_v7a*|*armeabi-v7a*) printf 'armeabi-v7a' ;;
    *x86_64*)                 printf 'x86_64'     ;;
    *x86*)                    printf 'x86'        ;;
    *armeabi*)                printf 'armeabi'    ;;
    *)                        printf 'none'       ;;  # base.apk, dpi, lang splits
  esac
}

# Pre-extract native libs from all APKs in a destination directory.
# Places .so files in lib/<abi>/ alongside the APK, mirroring how AOSP ships
# its own system apps. Required because /product is read-only at runtime —
# Android cannot extract libs there itself, causing UnsatisfiedLinkError crashes.
extract_native_libs() {
  local dest="$1"
  local extracted=0
  for _apk in "$dest"/*.apk; do
    [ -f "$_apk" ] || continue
    for _abi in $DEV_ABIS; do
      # Check if this APK has any .so for this ABI
      _has_so="$(unzip -l "$_apk" 2>/dev/null | grep "lib/$_abi/.*\.so" || true)"
      [ -z "$_has_so" ] && continue
      mkdir -p "$dest/lib/$_abi"
      unzip -j -o "$_apk" "lib/$_abi/*.so" -d "$dest/lib/$_abi/" 2>/dev/null || true
      extracted=$(( extracted + 1 ))
      break  # only extract for the first (primary) matching ABI per APK
    done
  done
  if [ "$extracted" -gt 0 ]; then
    # Fix perms on extracted .so files
    find "$dest/lib" -type f -exec chmod 0644 {} +
    find "$dest/lib" -type d -exec chmod 0755 {} +
    chown -R 0:0 "$dest/lib"
    python3 -c "
import os, sys
ctx = b'u:object_r:system_file:s0\x00'
for root, dirs, files in os.walk(sys.argv[1]):
    try: os.setxattr(root, 'security.selinux', ctx, follow_symlinks=False)
    except Exception: pass
    for f in files:
        try: os.setxattr(os.path.join(root, f), 'security.selinux', ctx, follow_symlinks=False)
        except Exception: pass
" "$dest/lib"
    say "  extracted native libs → lib/"
  fi
}

abi_compatible() {
  local abis="$1"
  [ "$abis" = "none" ] && return 0
  for da in $DEV_ABIS; do
    case ",$abis," in *",$da,"*) return 0 ;; esac
  done
  return 1
}

# Set root ownership, standard permissions, and SELinux xattr on a path tree
fix() {
  local path="$1"
  chown -R 0:0 "$path"
  find "$path" -type d -exec chmod 0755 {} +
  find "$path" -type f -exec chmod 0644 {} +
  python3 -c "
import os, sys
ctx = b'u:object_r:system_file:s0\x00'
for root, dirs, files in os.walk(sys.argv[1]):
    try: os.setxattr(root, 'security.selinux', ctx, follow_symlinks=False)
    except Exception: pass
    for f in files:
        try: os.setxattr(os.path.join(root, f), 'security.selinux', ctx, follow_symlinks=False)
        except Exception: pass
" "$path"
}

# Grow the image by at least $1 bytes, rounded up to the nearest 64 MB
grow_image() {
  local deficit="$1"
  local mb64=$((64 * 1024 * 1024))
  local grow=$(( ( (deficit + mb64 - 1) / mb64 ) * mb64 ))
  local grow_mb=$(( grow / 1024 / 1024 ))
  echo "==> Auto-growing image by ${grow_mb} MB..."
  truncate -s "+${grow}" "$OUTPUT_IMG"
  # e2fsck exit code 1 means "errors corrected" — that is success, not failure
  e2fsck -f -p "$OUTPUT_IMG" 2>&1 || true
  resize2fs "$OUTPUT_IMG" 2>&1
  say "Image is now $(du -h "$OUTPUT_IMG" | cut -f1)"
  echo ""
}

# ── phase 1: pre-scan (read-only mount) to calculate net new bytes needed ────
# Ensure the loop mount is always released on exit, even if the script crashes
trap 'umount "$MNT" 2>/dev/null || true' EXIT

echo "==> Checking space requirements..."
mkdir -p "$MNT"
mount -o loop,ro "$OUTPUT_IMG" "$MNT" 2>/dev/null \
  || die "pre-scan mount failed — is the image already mounted? (sudo umount $MNT)"

NET_NEEDED=0

# Scan app/ and priv-app/ together
for d in "$PRODUCT_SRC/app"/*/ "$PRODUCT_SRC/priv-app"/*/; do
  [ -d "$d" ] || continue
  folder="$(basename "$d")"
  case "$d" in */priv-app/*) ptype="priv-app" ;; *) ptype="app" ;; esac

  # Must have at least one APK
  _has_apk=0
  for _f in "$d"*.apk; do [ -f "$_f" ] && _has_apk=1 && break; done
  [ "$_has_apk" = "1" ] || continue

  abi_compatible "$(folder_abis "$d")" || continue   # skip ABI-incompatible

  # Sum ALL APKs in source folder (handles split bundles)
  # Also add estimated native lib extraction size (libs are stored compressed in APK,
  # so extracted .so files will be larger — use uncompressed size from zip header)
  new_sz=0
  for _apk in "$d"*.apk; do
    [ -f "$_apk" ] || continue
    new_sz=$(( new_sz + $(stat -c %s "$_apk") ))
    # Add uncompressed size of arm64 .so files (they'll be pre-extracted alongside APK)
    _so_sz="$(unzip -v "$_apk" 2>/dev/null | awk '/lib\/arm64/{sum+=$1} END{print sum+0}')"
    new_sz=$(( new_sz + _so_sz ))
  done

  # Sum existing APKs already in image (for accurate delta)
  ex_sz=0
  for _apk in "$MNT/$ptype/$folder/"*.apk; do
    [ -f "$_apk" ] && ex_sz=$(( ex_sz + $(stat -c %s "$_apk") ))
  done

  delta=$(( new_sz - ex_sz ))
  [ "$delta" -gt 0 ] && NET_NEEDED=$(( NET_NEEDED + delta ))
done

# Scan permission XMLs
for xml in "$PRODUCT_SRC/etc/permissions"/*.xml; do
  [ -f "$xml" ] || continue
  fname="$(basename "$xml")"
  new_sz="$(stat -c %s "$xml")"
  dest="$MNT/etc/permissions/$fname"
  if [ -f "$dest" ]; then
    ex_sz="$(stat -c %s "$dest")"
    delta=$(( new_sz - ex_sz ))
    [ "$delta" -gt 0 ] && NET_NEEDED=$(( NET_NEEDED + delta ))
  else
    NET_NEEDED=$(( NET_NEEDED + new_sz ))
  fi
done

# Read free space (df reports Available in 1K blocks; multiply to bytes)
FREE_BYTES="$(df -k "$MNT" 2>/dev/null \
  | awk 'END{for(j=1;j<=NF;j++) if($j ~ /%$/){print $(j-1)*1024; exit}}')"
[ -z "$FREE_BYTES" ] && FREE_BYTES=0

NET_MB=$(( NET_NEEDED / 1024 / 1024 ))
FREE_MB=$(( FREE_BYTES / 1024 / 1024 ))
say "Net new data needed : ${NET_MB} MB"
say "Free space in image : ${FREE_MB} MB"

umount "$MNT"

# ── grow image if needed (80 MB safety buffer) ────────────────────────────────
BUFFER=$(( 80 * 1024 * 1024 ))
if [ "$FREE_BYTES" -eq 0 ]; then
  say "WARNING: could not read free space — skipping auto-grow check"
  say "(If injection fails with 'no space left on device', see GUIDE.md Part 5)"
elif [ $(( NET_NEEDED + BUFFER )) -gt "$FREE_BYTES" ]; then
  DEFICIT=$(( NET_NEEDED + BUFFER - FREE_BYTES ))
  grow_image "$DEFICIT"
else
  say "Sufficient space — no resize needed"
  echo ""
fi

# ── phase 2: read-write mount and inject ─────────────────────────────────────
mount -o loop "$OUTPUT_IMG" "$MNT" \
  || die "mount failed — is the image already mounted? (sudo umount $MNT)"
echo "Mounted $OUTPUT_IMG → $MNT"
df -h "$MNT"
echo ""

# ── inject app/ ──────────────────────────────────────────────────────────────
echo "==> Injecting app/"
INSTALLED=0; SKIPPED=0
for d in "$PRODUCT_SRC/app"/*/; do
  [ -d "$d" ] || continue
  folder="$(basename "$d")"

  _has_apk=0
  for _f in "$d"*.apk; do [ -f "$_f" ] && _has_apk=1 && break; done
  [ "$_has_apk" = "1" ] || { say "SKIP (no apk): $folder"; continue; }

  abis="$(folder_abis "$d")"
  if ! abi_compatible "$abis"; then
    say "SKIP (ABI $abis not in {$DEV_ABIS}): $folder"
    SKIPPED=$(( SKIPPED + 1 )); continue
  fi

  dest="$MNT/app/$folder"
  mkdir -p "$dest"
  _n=0
  for _apk in "$d"*.apk; do
    [ -f "$_apk" ] || continue
    _skip_abi="$(split_abi_from_name "$(basename "$_apk")")"
    if [ "$_skip_abi" != "none" ] && ! abi_compatible "$_skip_abi"; then
      say "  skip incompatible split: $(basename "$_apk")"
      continue
    fi
    cp "$_apk" "$dest/$(basename "$_apk")"
    _n=$(( _n + 1 ))
  done
  extract_native_libs "$dest"
  fix "$dest"
  [ "$_n" -gt 1 ] && say "+ app/$folder  ($abis) [split: $_n APKs]" \
                   || say "+ app/$folder  ($abis)"
  INSTALLED=$(( INSTALLED + 1 ))
done

# ── inject priv-app/ ─────────────────────────────────────────────────────────
echo ""
echo "==> Injecting priv-app/"
for d in "$PRODUCT_SRC/priv-app"/*/; do
  [ -d "$d" ] || continue
  folder="$(basename "$d")"

  _has_apk=0
  for _f in "$d"*.apk; do [ -f "$_f" ] && _has_apk=1 && break; done
  [ "$_has_apk" = "1" ] || { say "SKIP (no apk): $folder"; continue; }

  abis="$(folder_abis "$d")"
  if ! abi_compatible "$abis"; then
    say "SKIP (ABI): $folder"; SKIPPED=$(( SKIPPED + 1 )); continue
  fi

  dest="$MNT/priv-app/$folder"
  mkdir -p "$dest"
  _n=0
  for _apk in "$d"*.apk; do
    [ -f "$_apk" ] || continue
    _skip_abi="$(split_abi_from_name "$(basename "$_apk")")"
    if [ "$_skip_abi" != "none" ] && ! abi_compatible "$_skip_abi"; then
      say "  skip incompatible split: $(basename "$_apk")"
      continue
    fi
    cp "$_apk" "$dest/$(basename "$_apk")"
    _n=$(( _n + 1 ))
  done
  extract_native_libs "$dest"
  fix "$dest"
  [ "$_n" -gt 1 ] && say "+ priv-app/$folder  [split: $_n APKs]" \
                   || say "+ priv-app/$folder"
  INSTALLED=$(( INSTALLED + 1 ))
done

# ── inject privapp-permissions XMLs ──────────────────────────────────────────
echo ""
echo "==> Injecting etc/permissions/"
mkdir -p "$MNT/etc/permissions"
for xml in "$PRODUCT_SRC/etc/permissions"/*.xml; do
  [ -f "$xml" ] || continue
  fname="$(basename "$xml")"
  cp "$xml" "$MNT/etc/permissions/$fname"
  chown 0:0 "$MNT/etc/permissions/$fname"
  chmod 0644 "$MNT/etc/permissions/$fname"
  python3 -c "
import os, sys
os.setxattr(sys.argv[1], 'security.selinux', b'u:object_r:system_file:s0\x00', follow_symlinks=False)
" "$MNT/etc/permissions/$fname"
  say "+ etc/permissions/$fname"
done

# ── final space check ─────────────────────────────────────────────────────────
echo ""
echo "==> Final space on image:"
df -h "$MNT"

# ── unmount ───────────────────────────────────────────────────────────────────
sync
umount "$MNT"
echo ""
echo "==> Done. Unmounted cleanly."
echo "    Installed : $INSTALLED apps"
echo "    Skipped   : $SKIPPED apps (ABI-incompatible)"
echo ""
echo "    Next: run  bash flash_product.sh"
echo "    (auto-detects your device, reboots to fastboot, and flashes automatically)"
