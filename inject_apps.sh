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
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# ── logging ───────────────────────────────────────────────────────────────────
LOG_DIR="$HERE/Logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/Logs_$(date '+%d-%m-%Y_%H:%M:%S').txt"
exec > >(tee "$LOGFILE") 2>&1
TEE_PID=$!

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

echo "  Log: $LOGFILE"
echo ""

# ── pre-flight checks ────────────────────────────────────────────────────────
[ -f "$INPUT_IMG" ]   || die "Input image not found: $INPUT_IMG
  Run:  bash extract_payload.sh   (place your ROM zip in payload_(or)_ROM-file/ first)"
[ -d "$PRODUCT_SRC" ] || die "Source dir not found: $PRODUCT_SRC"

# Validate the input image is a real ext4 filesystem before we do anything with it
tune2fs -l "$INPUT_IMG" >/dev/null 2>&1 \
  || die "Input image does not appear to be a valid ext4 filesystem: $INPUT_IMG
  Re-run:  bash extract_payload.sh"

command -v python3   >/dev/null 2>&1 || die "python3 required  (sudo apt install python3)"
command -v unzip     >/dev/null 2>&1 || die "unzip required    (sudo apt install unzip)"
command -v e2fsck    >/dev/null 2>&1 || die "e2fsck required   (sudo apt install e2fsprogs)"
command -v resize2fs >/dev/null 2>&1 || die "resize2fs required (sudo apt install e2fsprogs)"
command -v tune2fs   >/dev/null 2>&1 || die "tune2fs required  (sudo apt install e2fsprogs)"

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
  # Last resort: inspect the image for lib64/ vs lib/ to guess ABI family
  if tune2fs -l "$INPUT_IMG" 2>/dev/null | grep -q ""; then
    # Can't inspect without mounting; default to arm64 + 32-bit compat
    DEV_ABIS="arm64-v8a armeabi-v7a armeabi"
  fi
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

apk_abis() {
  local apk="$1" abis
  abis="$(unzip -l "$apk" 2>/dev/null | grep -oE 'lib/[^/]+/' | sed 's|lib/||;s|/||' | sort -u | paste -sd, - || true)"
  [ -z "$abis" ] && abis="none"
  printf '%s' "$abis"
}

folder_abis() {
  local dir="$1" apk bname abis
  for apk in "$dir"*.apk; do
    [ -f "$apk" ] || continue
    bname="$(basename "$apk")"
    case "$bname" in
      *arm64_v8a*|*arm64-v8a*) printf 'arm64-v8a';   return ;;
      *armeabi_v7a*|*armeabi-v7a*) printf 'armeabi-v7a'; return ;;
      *x86_64*)                 printf 'x86_64';     return ;;
      *x86*)                    printf 'x86';        return ;;
      *armeabi*)                printf 'armeabi';    return ;;
    esac
    abis="$(apk_abis "$apk")"
    [ "$abis" != "none" ] && { printf '%s' "$abis"; return; }
  done
  printf 'none'
}

split_abi_from_name() {
  case "$1" in
    *arm64_v8a*|*arm64-v8a*) printf 'arm64-v8a'   ;;
    *armeabi_v7a*|*armeabi-v7a*) printf 'armeabi-v7a' ;;
    *x86_64*)                 printf 'x86_64'     ;;
    *x86*)                    printf 'x86'        ;;
    *armeabi*)                printf 'armeabi'    ;;
    *)                        printf 'none'       ;;
  esac
}

extract_native_libs() {
  local dest="$1"
  local is_priv=0
  case "$dest" in */priv-app/*) is_priv=1 ;; esac

  local extracted=0
  local _plibdir=""
  for _apk in "$dest"/*.apk; do
    [ -f "$_apk" ] || continue
    for _abi in $DEV_ABIS; do
      _has_so="$(unzip -l "$_apk" 2>/dev/null | grep "lib/$_abi/.*\.so" || true)"
      [ -z "$_has_so" ] && continue

      mkdir -p "$dest/lib/$_abi"
      unzip -j -o "$_apk" "lib/$_abi/*.so" -d "$dest/lib/$_abi/" 2>/dev/null || true

      if [ "$is_priv" = "1" ]; then
        # Privileged apps: PMS does not set nativeLibraryDir from lib/<abi>/.
        # Copy to partition shared lib dir (/product/lib64/) so bare-name dlopen works.
        case "$_abi" in
          arm64-v8a|x86_64) _plibdir="$MNT/lib64" ;;
          *)                 _plibdir="$MNT/lib"   ;;
        esac
        mkdir -p "$_plibdir"
        for _so in "$dest/lib/$_abi"/*.so; do
          [ -f "$_so" ] || continue
          cp "$_so" "$_plibdir/$(basename "$_so")"
        done
      fi

      extracted=$(( extracted + 1 ))
      break
    done
  done

  if [ "$extracted" -gt 0 ]; then
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

    if [ "$is_priv" = "1" ] && [ -n "$_plibdir" ]; then
      find "$_plibdir" -maxdepth 1 -name "*.so" -exec chmod 0644 {} + 2>/dev/null || true
      find "$_plibdir" -maxdepth 1 -name "*.so" -exec chown 0:0 {} + 2>/dev/null || true
      python3 -c "
import os, sys, glob
ctx = b'u:object_r:system_file:s0\x00'
for f in glob.glob(sys.argv[1] + '/*.so'):
    try: os.setxattr(f, 'security.selinux', ctx, follow_symlinks=False)
    except Exception: pass
" "$_plibdir" 2>/dev/null || true
      say "  → also copied to $(basename "$_plibdir")/ (priv-app linker workaround)"
    fi
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

# Grow the image by at least $1 bytes, rounded up to the nearest 64 MB.
# Aborts on any tool failure — a half-grown image is worse than no image.
grow_image() {
  local deficit="$1"
  local mb64=$((64 * 1024 * 1024))
  local grow=$(( ( (deficit + mb64 - 1) / mb64 ) * mb64 ))
  local grow_mb=$(( grow / 1024 / 1024 ))
  local host_free
  host_free="$(df -h "$(dirname "$OUTPUT_IMG")" 2>/dev/null | tail -1 | awk '{print $4}')"
  echo "==> Auto-growing image by ${grow_mb} MB (host has ${host_free:-?} free)..."
  truncate -s "+${grow}" "$OUTPUT_IMG" \
    || die "truncate failed — not enough disk space on host? (need ~${grow_mb} MB free)"
  # e2fsck exit 0 = clean, 1 = errors corrected (both acceptable); 2+ = serious
  local _fsck_rc=0
  e2fsck -f -p "$OUTPUT_IMG" 2>&1 || _fsck_rc=$?
  if [ "$_fsck_rc" -gt 1 ]; then
    die "e2fsck reported serious filesystem errors (exit $_fsck_rc).
  The image may be corrupt. Restore from: $INPUT_IMG"
  fi
  resize2fs "$OUTPUT_IMG" 2>&1 \
    || die "resize2fs failed — e2fsprogs may be outdated (sudo apt install --reinstall e2fsprogs)"
  say "Image is now $(du -h "$OUTPUT_IMG" | cut -f1)"
  echo ""
}

# ── exit trap: unmount and delete incomplete output to prevent bad flashes ────
INJECT_SUCCESS=0
_cleanup() {
  local _ec=$?
  umount "$MNT" 2>/dev/null || true
  # Wait for the tee log process to flush before exiting
  # Close the pipe to tee so it can exit, then wait for it
  exec >&- 2>&-
  wait "$TEE_PID" 2>/dev/null || true
  if [ "$INJECT_SUCCESS" = "0" ] && [ "$_ec" -ne 0 ]; then
    # Reopen stderr to the terminal so abort messages are visible
    exec 2>/dev/tty || true
    echo "" >&2
    echo "  ABORTED (exit $_ec) — removing incomplete output image to prevent a bad flash." >&2
    rm -f "$OUTPUT_IMG" 2>/dev/null || true
    echo "  Safe to re-run: sudo bash inject_apps.sh" >&2
    echo "  Log saved: $LOGFILE" >&2
  fi
}
trap '_cleanup' EXIT

# ── phase 1: pre-scan (read-only mount) to calculate net new bytes needed ────
echo "==> Checking space requirements..."
mkdir -p "$MNT"
mount -o loop,ro "$OUTPUT_IMG" "$MNT" 2>/dev/null \
  || die "pre-scan mount failed — is the image already mounted? (sudo umount $MNT)"

NET_NEEDED=0

for d in "$PRODUCT_SRC/app"/*/ "$PRODUCT_SRC/priv-app"/*/; do
  [ -d "$d" ] || continue
  folder="$(basename "$d")"
  case "$d" in */priv-app/*) ptype="priv-app" ;; *) ptype="app" ;; esac

  _has_apk=0
  for _f in "$d"*.apk; do [ -f "$_f" ] && _has_apk=1 && break; done
  [ "$_has_apk" = "1" ] || continue

  abi_compatible "$(folder_abis "$d")" || continue

  new_sz=0
  for _apk in "$d"*.apk; do
    [ -f "$_apk" ] || continue
    new_sz=$(( new_sz + $(stat -c %s "$_apk") ))
    _so_sz="$(unzip -v "$_apk" 2>/dev/null | awk '/lib\/arm64/{sum+=$1} END{print sum+0}')"
    new_sz=$(( new_sz + _so_sz ))
  done

  ex_sz=0
  for _apk in "$MNT/$ptype/$folder/"*.apk; do
    [ -f "$_apk" ] && ex_sz=$(( ex_sz + $(stat -c %s "$_apk") ))
  done

  delta=$(( new_sz - ex_sz ))
  [ "$delta" -gt 0 ] && NET_NEEDED=$(( NET_NEEDED + delta ))
done

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

# Read free space. Empty string = df parse failed; "0" = filesystem genuinely full.
FREE_BYTES="$(df -k "$MNT" 2>/dev/null \
  | awk 'END{for(j=1;j<=NF;j++) if($j ~ /%$/){print $(j-1)*1024; exit}}')"

NET_MB=$(( NET_NEEDED / 1024 / 1024 ))
FREE_MB=$(( ${FREE_BYTES:-0} / 1024 / 1024 ))
say "Net new data needed : ${NET_MB} MB"
say "Free space in image : ${FREE_MB} MB"

umount "$MNT"

# ── grow image if needed (80 MB safety buffer) ────────────────────────────────
BUFFER=$(( 80 * 1024 * 1024 ))
if [ -z "$FREE_BYTES" ]; then
  # df parse failed (no output) — grow conservatively so we don't run out
  say "WARNING: could not read free space from df — growing by net needed + buffer"
  grow_image $(( NET_NEEDED + BUFFER ))
elif [ $(( NET_NEEDED + BUFFER )) -gt "$FREE_BYTES" ]; then
  DEFICIT=$(( NET_NEEDED + BUFFER - FREE_BYTES ))
  grow_image "$DEFICIT"
else
  say "Sufficient space (${FREE_MB} MB free, need ${NET_MB} MB + 80 MB buffer) — no resize needed"
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
try: os.setxattr(sys.argv[1], 'security.selinux', b'u:object_r:system_file:s0\x00', follow_symlinks=False)
except Exception: pass
" "$MNT/etc/permissions/$fname"
  say "+ etc/permissions/$fname"
done

# ── all injection done — mark success before unmount ─────────────────────────
# Set this before sync/umount so a signal during cleanup doesn't delete a good image
INJECT_SUCCESS=1

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
echo "    Log saved : $LOGFILE"
echo ""
echo "    Next: run  bash flash_product.sh"
