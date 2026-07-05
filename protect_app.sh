#!/usr/bin/env bash
# protect_app.sh — mark an injected system app as permanently non-disableable in Settings
#
# USAGE:  bash protect_app.sh [OPTIONS]
#
# OPTIONS:
#   --apk-dir <path>   Folder under product/app/<Name> or product/priv-app/<Name>
#                      containing the app's APK(s). Package name is extracted
#                      via aapt — recommended, avoids typo'd package names.
#   --package <name>   Package name to protect directly, when the APK isn't
#                      in the tree yet.
#   --src     <path>   Path to the product/ source tree (default: ./product)
#
# Writes product/etc/permissions/prevent-disable-<package>.xml, which
# inject_apps.sh already copies into the image unchanged (no changes to
# inject_apps.sh needed). Uses AOSP's own <prevent-disable> sysconfig tag
# (frameworks/base SystemConfig.java) — the same mechanism that keeps the
# default dialer/SMS app/WebView provider permanently enabled.
#
# Also checks (read-only) whether the APK's manifest blocks "Clear data" via
# android:allowClearUserData="false". Unlike Disable, this can't be set by an
# external file — it has to be baked into the APK's own manifest and rebuilt.
# The script only reports the current state and tells you what to change.
#
# LIMITS: greys the Disable button in Settings; NOT enforced by
# PackageManagerService, so `adb shell pm disable-user` still bypasses it
# (verified against AOSP source). The app must be shipped as a system app
# (product/app or product/priv-app) for this to have any effect. Force Stop
# has no equivalent build-time protection in AOSP and is intentionally left
# permissive by design — not something this script can change.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# ── logging ───────────────────────────────────────────────────────────────────
LOG_DIR="$HERE/Logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/Logs_$(date '+%d-%m-%Y_%H:%M:%S').txt"
exec > >(tee "$LOGFILE") 2>&1
TEE_PID=$!

# ── defaults (overridable via flags) ─────────────────────────────────────────
PRODUCT_SRC="$HERE/product"
APK_DIR=""
PACKAGE=""

# ── parse flags ──────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --apk-dir) APK_DIR="$2";     shift 2 ;;
    --package) PACKAGE="$2";     shift 2 ;;
    --src)     PRODUCT_SRC="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1  (use --help)" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "  $*"; }

echo "  Log: $LOGFILE"
echo ""

[ -n "$APK_DIR" ] || [ -n "$PACKAGE" ] || die "Need --apk-dir or --package  (use --help)"
if [ -n "$APK_DIR" ] && [ -n "$PACKAGE" ]; then
  die "Pass --apk-dir OR --package, not both"
fi

extract_package() {
  aapt dump badging "$1" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p"
}

# Prints "blocked" if the APK's manifest sets android:allowClearUserData="false"
# on <application>, else "allowed" (covers both explicit true and the default).
clear_data_status() {
  local attr
  attr="$(aapt dump xmltree "$1" AndroidManifest.xml 2>/dev/null | awk '
    /E: application /  { infound=1; next }
    infound && /^      E: / { exit }
    infound && /android:allowClearUserData/ { print; exit }
  ')"
  case "$attr" in
    *'(type 0x12)0x0'*) printf 'blocked' ;;
    *)                  printf 'allowed' ;;
  esac
}

report_clear_data() {
  local apk="$1"
  if [ "$(clear_data_status "$apk")" = "blocked" ]; then
    say "Clear Data: already blocked (android:allowClearUserData=\"false\" is set)"
  else
    say "Clear Data: NOT blocked (android:allowClearUserData is true or unset)"
    say "  This can't be set externally like the Disable protection — add"
    say "  android:allowClearUserData=\"false\" to <application> in this app's"
    say "  own AndroidManifest.xml and rebuild the APK."
  fi
}

# ── resolve package name ─────────────────────────────────────────────────────
if [ -n "$APK_DIR" ]; then
  [ -f "$APK_DIR" ] && APK_DIR="$(dirname "$APK_DIR")"
  [ -d "$APK_DIR" ] || die "Not a directory: $APK_DIR"
  command -v aapt >/dev/null 2>&1 || die "aapt required — add Android SDK build-tools to PATH:
  export PATH=\"\$PATH:\$HOME/Android/Sdk/build-tools/\$(ls \$HOME/Android/Sdk/build-tools | sort -V | tail -1)\""

  APK=""
  [ -f "$APK_DIR/base.apk" ] && APK="$APK_DIR/base.apk"
  if [ -z "$APK" ]; then
    for f in "$APK_DIR"/*.apk; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in split_config.*) continue ;; esac
      APK="$f"; break
    done
  fi
  [ -n "$APK" ] || die "No APK found in $APK_DIR"

  PACKAGE="$(extract_package "$APK")"
  [ -n "$PACKAGE" ] || die "Could not extract package name from $APK"
  say "Resolved package: $PACKAGE  (from $(basename "$APK"))"
  report_clear_data "$APK"
else
  echo "$PACKAGE" | grep -qE '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$' \
    || die "Package name doesn't look valid: $PACKAGE  (expected e.g. com.example.app)"

  FOUND=0
  MATCHED_APK=""
  if command -v aapt >/dev/null 2>&1; then
    for d in "$PRODUCT_SRC/app"/*/ "$PRODUCT_SRC/priv-app"/*/; do
      [ -d "$d" ] || continue
      for f in "$d"*.apk; do
        [ -f "$f" ] || continue
        [ "$(extract_package "$f")" = "$PACKAGE" ] && { FOUND=1; MATCHED_APK="$f"; break 2; }
      done
    done
  fi
  if [ "$FOUND" = "1" ]; then
    report_clear_data "$MATCHED_APK"
  else
    say "WARNING: no APK under $PRODUCT_SRC/{app,priv-app} matches '$PACKAGE' yet — this entry will be inert until it's shipped there as a system app."
  fi
fi

# ── write the sysconfig entry ────────────────────────────────────────────────
PERMS_DIR="$PRODUCT_SRC/etc/permissions"
mkdir -p "$PERMS_DIR"
OUT_XML="$PERMS_DIR/prevent-disable-$PACKAGE.xml"

cat > "$OUT_XML" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <prevent-disable package="$PACKAGE" />
</permissions>
EOF

echo ""
echo "==> Wrote $OUT_XML"
say "package: $PACKAGE"
echo ""
echo "    Next: sudo bash inject_apps.sh   (picks this up automatically)"
echo "          bash flash_product.sh"
