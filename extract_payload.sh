#!/usr/bin/env bash
# extract_payload.sh — find ROM payload, install payload_dumper if needed,
#                      extract product.img and vbmeta images to the right dirs
#
# USAGE:  bash extract_payload.sh [OPTIONS]
#
# OPTIONS:
#   --payload   <path>   Path to payload.bin or ROM zip (default: auto-detect in payload/)
#   --input-dir <path>   Where to write product.img (default: input/)
#   --output-dir <path>  Where to write vbmeta images (default: output/)
#   --dumper    <path>   Path to payload_dumper binary (default: auto-detect)
#
# Place your ROM zip or payload.bin inside the payload/ folder and run this
# script. It will:
#   1. Auto-detect the file to use
#   2. Install payload_dumper if not already on the system
#   3. Extract product.img  → input/   (base image for inject_apps.sh)
#   4. Extract vbmeta*.img  → output/  (for one-time AVB disable flash)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# When run via sudo, HOME becomes /root — resolve the real user's home too
REAL_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ]; then
  REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")"
fi

# ── defaults ──────────────────────────────────────────────────────────────────
PAYLOAD_DIR="$HERE/payload_(or)_ROM-file"
SOURCE=""
INPUT_DIR="$HERE/input"
OUTPUT_DIR="$HERE/output"
DUMPER=""

# ── parse flags ───────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --payload)    SOURCE="$2";      shift 2 ;;
    --input-dir)  INPUT_DIR="$2";   shift 2 ;;
    --output-dir) OUTPUT_DIR="$2";  shift 2 ;;
    --dumper)     DUMPER="$2";      shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1  (use --help)" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "  $*"; }

echo ""
echo "========================================================"
echo "  extract_payload.sh"
echo "========================================================"
echo ""

# ── step 1: find source file ──────────────────────────────────────────────────
if [ -z "$SOURCE" ]; then
  # Prefer payload.bin if it exists
  if [ -f "$PAYLOAD_DIR/payload.bin" ]; then
    SOURCE="$PAYLOAD_DIR/payload.bin"
    say "Found: $SOURCE"
  else
    # Look for a zip file
    _zip=""
    _newest=0
    for _f in "$PAYLOAD_DIR"/*.zip; do
      [ -f "$_f" ] || continue
      _mtime="$(stat -c %Y "$_f" 2>/dev/null || echo 0)"
      if [ "$_mtime" -gt "$_newest" ]; then
        _newest="$_mtime"
        _zip="$_f"
      fi
    done
    if [ -n "$_zip" ]; then
      SOURCE="$_zip"
      say "Found ROM zip: $SOURCE"
    fi
  fi
fi

[ -n "$SOURCE" ] || die "No payload.bin or ROM zip found in $PAYLOAD_DIR/
  Place your ROM zip or payload.bin in the payload/ folder and re-run."
[ -f "$SOURCE" ] || die "File not found: $SOURCE"

echo ""

# ── step 2: find payload_dumper ───────────────────────────────────────────────
find_dumper() {
  for _candidate in \
      "payload_dumper" \
      "$REAL_HOME/.extra/bin/payload_dumper" \
      "$REAL_HOME/.local/bin/payload_dumper" \
      "$REAL_HOME/bin/payload_dumper" \
      "$HOME/.extra/bin/payload_dumper" \
      "$HOME/.local/bin/payload_dumper" \
      "$HOME/bin/payload_dumper" \
      "/usr/local/bin/payload_dumper" \
      "/usr/bin/payload_dumper"; do
    if command -v "$_candidate" >/dev/null 2>&1 || [ -x "$_candidate" ]; then
      printf '%s' "$_candidate"
      return 0
    fi
  done
  return 1
}

if [ -n "$DUMPER" ]; then
  [ -x "$DUMPER" ] || die "payload_dumper not executable: $DUMPER"
  say "Using specified dumper: $DUMPER"
else
  echo "==> Locating payload_dumper..."
  if DUMPER="$(find_dumper)"; then
    say "Found: $DUMPER"
  else
    echo "  Not found in PATH or common locations."
    echo "  Attempting install via pip3/pipx..."
    if command -v pipx >/dev/null 2>&1; then
      pipx install ota-payload-dumper 2>/dev/null || true
    elif command -v pip3 >/dev/null 2>&1; then
      pip3 install --quiet --break-system-packages ota-payload-dumper 2>/dev/null \
        || pip3 install --quiet ota-payload-dumper 2>/dev/null \
        || true
    fi
    DUMPER="$(find_dumper)" || true
    if [ -z "$DUMPER" ]; then
      die "payload_dumper not found and could not be installed automatically.

  Install it manually — choose one:
    • Recommended (Rust binary, fast):
        Download from https://github.com/ssut/payload-dumper-go/releases
        and place it somewhere in your PATH (e.g. ~/.local/bin/payload_dumper)
    • Python via pip:
        pip3 install ota-payload-dumper
    • Then re-run this script."
    fi
    say "Installed and found: $DUMPER"
  fi
fi

echo ""

# ── step 3: prepare directories ──────────────────────────────────────────────
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# ── step 4: extract product.img → input/ ────────────────────────────────────
echo "==> Extracting product.img → $INPUT_DIR/ ..."
if [ -f "$INPUT_DIR/product.img" ]; then
  say "Note: overwriting existing $INPUT_DIR/product.img"
fi

"$DUMPER" --images product --out "$INPUT_DIR" "$SOURCE"

[ -f "$INPUT_DIR/product.img" ] \
  || die "product.img was not produced — check payload_dumper output above."
say "product.img: $(du -h "$INPUT_DIR/product.img" | cut -f1)"

echo ""

# ── step 5: extract vbmeta images → output/ ──────────────────────────────────
echo "==> Extracting vbmeta images → $OUTPUT_DIR/ ..."

# Try to extract both at once; vbmeta_system may not exist in all ROMs
"$DUMPER" --images vbmeta,vbmeta_system --out "$OUTPUT_DIR" "$SOURCE" 2>&1 \
  | grep -v "^$" | sed 's/^/  /' || true

# If vbmeta_system wasn't produced, try vbmeta alone (some payloads only have vbmeta)
if [ ! -f "$OUTPUT_DIR/vbmeta.img" ]; then
  "$DUMPER" --images vbmeta --out "$OUTPUT_DIR" "$SOURCE"
fi

[ -f "$OUTPUT_DIR/vbmeta.img" ] \
  || die "vbmeta.img was not produced — does this payload contain a vbmeta partition?"

say "vbmeta.img: $(du -h "$OUTPUT_DIR/vbmeta.img" | cut -f1)"
if [ -f "$OUTPUT_DIR/vbmeta_system.img" ]; then
  say "vbmeta_system.img: $(du -h "$OUTPUT_DIR/vbmeta_system.img" | cut -f1)"
else
  say "vbmeta_system.img: not present in this ROM (that's fine)"
fi

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo "  Done!"
echo ""
echo "  input/product.img is your stock baseline."
echo "  It is never modified — inject_apps.sh always starts"
echo "  from a fresh copy of it."
echo ""
echo "  Next steps:"
echo "    1. Flash vbmeta to disable AVB (first time only):"
echo "         fastboot flash vbmeta_a   --disable-verity --disable-verification output/vbmeta.img"
echo "         fastboot flash vbmeta_b   --disable-verity --disable-verification output/vbmeta.img"
if [ -f "$OUTPUT_DIR/vbmeta_system.img" ]; then
  echo "         fastboot flash vbmeta_system_a   --disable-verity --disable-verification output/vbmeta_system.img"
  echo "         fastboot flash vbmeta_system_b   --disable-verity --disable-verification output/vbmeta_system.img"
fi
echo ""
echo "    2. Add your APKs to product/app/ and product/priv-app/"
echo "    3. sudo bash inject_apps.sh"
echo "    4. bash flash_product.sh"
echo "========================================================"
echo ""
