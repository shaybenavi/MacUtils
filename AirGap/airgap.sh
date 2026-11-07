#!/bin/bash
#
# airgap.sh - lock a MacBook down to "IPv4 over Wi-Fi only", with SIP left ON.
#
#   sudo bash airgap.sh install     apply everything and keep it enforced
#   sudo bash airgap.sh status      show what is in effect
#   sudo bash airgap.sh uninstall   undo everything this script did
#
# What "install" does
#
#   Kept enforced permanently (at boot, whenever network settings change, and every 5 min):
#     - pf firewall: loopback stays open; ALL IPv6 is dropped; IPv4 is allowed only
#       outbound over Wi-Fi (plus the replies, plus DHCP). Ethernet / USB adapters,
#       iPhone tethering, Thunderbolt Bridge, Bluetooth PAN, AirDrop's awdl0, VPN tunnels
#       and every unsolicited inbound packet are dropped.
#     - Every network service except Wi-Fi is disabled, including adapters plugged in later.
#     - IPv6 is set to Off on every network service, Wi-Fi included.
#     - No multicast out over Wi-Fi either, so the Mac stops announcing itself (Bonjour,
#       SSDP) on the local network.
#     - One exception: on Macs with a T2 chip, the T2's internal link (an interface with
#       the fixed address ac:de:48:00:11:22, usually en5) is left alone. It only connects
#       macOS to the T2 chip on the logic board, and the Touch Bar, camera and other T2
#       services depend on it.
#
#   Applied once:
#     - Application Firewall on, block all incoming, stealth mode.
#     - Bluetooth off. AirDrop, Handoff and AirPlay Receiver off.
#     - A configuration profile that keeps AirDrop, Handoff, AirPlay Receiver and Bluetooth
#       off. On Catalina the script installs it itself; on macOS 11 and later Apple only
#       lets you approve it by hand, so the script opens it for you.
#
# Works on macOS 10.15 Catalina and later, Intel or Apple silicon.
# Wi-Fi stays yours: turn it on and off as usual. Networks that are IPv6-only will not work.
# Nothing here touches SIP, Recovery or the system volume.

[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="local.airgap"
APP_DIR="/Library/Application Support/airgap"
BIN="$APP_DIR/airgap.sh"
STATE="$APP_DIR/services-before-install.tsv"
WIFI_CACHE="$APP_DIR/wifi-device"
T2_CACHE="$APP_DIR/t2-device"
T2_MAC="ac:de:48:00:11:22"
PROFILE="$APP_DIR/Airgap-Restrictions.mobileconfig"
PROFILE_ID="local.airgap.restrictions"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG="/var/log/airgap.log"
PF_CONF="/etc/pf.conf"
PF_BACKUP="/etc/pf.conf.before-airgap"
ANCHOR="airgap"
ANCHOR_FILE="/etc/pf.anchors/airgap"
ANCHOR_LINE='anchor "airgap"'
LOAD_LINE='load anchor "airgap" from "/etc/pf.anchors/airgap"'
MARK_LINE='# airgap.sh: managed line, removed by "airgap.sh uninstall"'
FW="/usr/libexec/ApplicationFirewall/socketfilterfw"
TAB="$(printf '\t')"

OS_VER="$(sw_vers -productVersion 2>/dev/null)"
OS_MAJOR="${OS_VER%%.*}"
case "$OS_MAJOR" in ""|*[!0-9]*) OS_MAJOR=0 ;; esac
if [ "$OS_MAJOR" -ge 13 ]; then
  SETTINGS="System Settings"
  PROFILES_PANE="System Settings > General > Device Management (or Privacy & Security > Profiles)"
  FIREWALL_PANE="System Settings > Network > Firewall"
else
  SETTINGS="System Preferences"
  PROFILES_PANE="System Preferences > Profiles"
  FIREWALL_PANE="System Preferences > Security & Privacy > Firewall"
fi

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
say() { printf '%s\n' "$*"; }
die() { printf 'airgap: %s\n' "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "needs root. Run: sudo bash \"$0\" $1"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/airgap.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- helpers ---

# The person logged in (the one who ran sudo), for per-user settings.
target_user() {
  local u="${SUDO_USER:-}"
  if [ -z "$u" ] || [ "$u" = "root" ]; then
    u="$(stat -f %Su /dev/console 2>/dev/null)"
  fi
  [ -n "$u" ] && [ "$u" != "root" ] && printf '%s' "$u"
}

as_user() {
  local u="$1"; shift
  launchctl asuser "$(id -u "$u")" sudo -u "$u" "$@"
}

is_admin() { dseditgroup -o checkmember -m "$1" admin >/dev/null 2>&1; }

# "Allow accessories to connect" exists only on Apple silicon laptops with macOS 13+.
has_accessory_setting() {
  [ "$OS_MAJOR" -ge 13 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]
}

# One line per network service: name <TAB> hardware port <TAB> device <TAB> Enabled|Disabled
# (device is "-" when the service has none, e.g. a VPN configuration).
list_services() {
  networksetup -listnetworkserviceorder 2>/dev/null </dev/null | awk '
    /^\([0-9]+\) / || /^\(\*\) / {
      state = ($0 ~ /^\(\*\) /) ? "Disabled" : "Enabled"
      svc = $0; sub(/^\([0-9*]+\) /, "", svc)
      next
    }
    /^\(Hardware Port: / && svc != "" {
      port = $0; sub(/^\(Hardware Port: /, "", port); sub(/, Device:.*$/, "", port)
      dev = ""
      if (match($0, /Device: [^)]*/)) dev = substr($0, RSTART + 8, RLENGTH - 8)
      gsub(/[ \t]+$/, "", dev)
      if (dev == "") dev = "-"
      printf "%s\t%s\t%s\t%s\n", svc, port, dev, state
      svc = ""
    }'
}

is_wifi_port() { [ "$1" = "Wi-Fi" ] || [ "$1" = "AirPort" ]; }

valid_ifname() {
  case "$1" in ""|*[!a-z0-9]*) return 1 ;; esac
  return 0
}

wifi_device() {
  local dev
  dev="$(list_services | awk -F'\t' '($2 == "Wi-Fi" || $2 == "AirPort") && $3 != "-" { print $3; exit }')"
  if ! valid_ifname "$dev"; then
    dev="$(networksetup -listallhardwareports 2>/dev/null </dev/null | awk '
      /^Hardware Port: (Wi-Fi|AirPort)$/ { f = 1; next }
      f && /^Device: / { print $2; exit }')"
  fi
  if valid_ifname "$dev"; then
    [ -d "$APP_DIR" ] && printf '%s\n' "$dev" > "$WIFI_CACHE"
  elif [ -f "$WIFI_CACHE" ]; then
    # Early in boot networksetup may not answer yet: use the last known Wi-Fi interface.
    dev="$(head -n 1 "$WIFI_CACHE")"
  fi
  valid_ifname "$dev" && printf '%s' "$dev"
}

# The T2 chip's internal USB-Ethernet link always uses this fixed MAC address.
t2_device() {
  local i dev=""
  for i in $(ifconfig -l 2>/dev/null); do
    if ifconfig "$i" 2>/dev/null | grep -qi "ether $T2_MAC"; then
      dev="$i"
      break
    fi
  done
  if valid_ifname "$dev"; then
    [ -d "$APP_DIR" ] && printf '%s\n' "$dev" > "$T2_CACHE"
  elif [ -f "$T2_CACHE" ]; then
    dev="$(head -n 1 "$T2_CACHE")"
  fi
  valid_ifname "$dev" && printf '%s' "$dev"
}

# Prints the service's IPv6 mode (Automatic, Off, Manual, ...) or "-" if it has none.
ipv6_state() {
  local v
  v="$(networksetup -getinfo "$1" 2>/dev/null </dev/null | awk -F': ' '/^IPv6: / { print $2; exit }')"
  printf '%s' "${v:--}"
}

# -------------------------------------------------------------------- pf ---

# $1 = Wi-Fi interface (may be empty), $2 = T2 internal interface (may be empty)
render_anchor() {
  printf '%s\n' \
    "# Generated by airgap.sh. Do not edit: it is rewritten automatically." \
    "# Policy: loopback open, no IPv6 at all, IPv4 only outbound over Wi-Fi, everything else dropped." \
    "pass quick on lo0 all"
  if [ -n "$2" ]; then
    printf '%s\n' \
      "# $2 is the T2 chip's internal link (MAC $T2_MAC), not a network: the Touch Bar, camera and other T2 services use it." \
      "pass quick on $2 all"
  fi
  printf '%s\n' "block drop quick inet6 all"
  if [ -n "$1" ]; then
    printf '%s\n' \
      "pass in quick on $1 inet proto udp from any port 67 to any port 68" \
      "block drop out quick on $1 inet from any to 224.0.0.0/4" \
      "pass out quick on $1 inet all keep state"
  else
    printf '%s\n' "# No Wi-Fi interface found, so nothing is allowed out."
  fi
  printf '%s\n' "block drop quick all"
}

pf_conf_has_lines() {
  [ -f "$PF_CONF" ] && grep -qxF "$ANCHOR_LINE" "$PF_CONF" && grep -qxF "$LOAD_LINE" "$PF_CONF"
}

strip_pf_lines() { grep -vxF -e "$ANCHOR_LINE" -e "$LOAD_LINE" -e "$MARK_LINE" || true; }

# Our anchor goes in front of Apple's, so its "quick" rules decide every packet.
patch_pf_conf() {
  [ -f "$PF_CONF" ] || : > "$PF_CONF"
  [ -f "$PF_BACKUP" ] || cp -p "$PF_CONF" "$PF_BACKUP"
  strip_pf_lines < "$PF_CONF" | awk -v mark="$MARK_LINE" -v anc="$ANCHOR_LINE" -v load="$LOAD_LINE" '
    !done && /^anchor "com\.apple\/\*"/ { print mark; print anc; done = 1 }
    { print }
    END {
      if (!done) { print mark; print anc }
      print mark; print load
    }' > "$TMP/pf.conf" || return 1
  cat "$TMP/pf.conf" > "$PF_CONF" || return 1
  log "Updated $PF_CONF"
}

pf_rules_active() {
  pfctl -sr 2>/dev/null | grep -qF "$ANCHOR_LINE" &&
    pfctl -a "$ANCHOR" -sr 2>/dev/null | grep -q 'block'
}

pf_enabled() { pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; }

# Fail closed: if our rules will not load, block everything (Wi-Fi too) rather than allow all.
pf_emergency() {
  printf '%s\n' 'pass quick on lo0 all' 'block drop quick all' | pfctl -f - >/dev/null 2>&1
  log "ERROR: airgap rules did not load, so emergency block-all rules are in place (Wi-Fi is blocked too). Check $PF_CONF and $ANCHOR_FILE."
}

# --------------------------------------------------------------- enforce ---

enforce() {
  local svc port dev state v6 wifi_dev t2_dev out reload=0

  t2_dev="$(t2_device)"

  # 1) Only Wi-Fi may be enabled, and IPv6 is off on every service (the T2 link excepted).
  list_services > "$TMP/services"
  while IFS="$TAB" read -r svc port dev state <&3; do
    [ -n "$svc" ] || continue
    if { [ -n "$t2_dev" ] && [ "$dev" = "$t2_dev" ]; } || [ "$port" = "iBridge" ]; then
      continue
    fi
    if [ "$dev" != "-" ]; then
      v6="$(ipv6_state "$svc")"
      if [ "$v6" != "-" ] && [ "$v6" != "Off" ]; then
        if networksetup -setv6off "$svc" >/dev/null 2>&1 </dev/null; then
          log "IPv6 turned off: $svc"
        else
          log "WARNING: could not turn IPv6 off for: $svc"
        fi
      fi
    fi
    is_wifi_port "$port" && continue
    if [ "$state" = "Enabled" ]; then
      if networksetup -setnetworkserviceenabled "$svc" off >/dev/null 2>&1 </dev/null; then
        log "Network service disabled: $svc ($port)"
      else
        log "WARNING: could not disable network service: $svc"
      fi
    fi
  done 3< "$TMP/services"

  # 2) pf rules, hooked into /etc/pf.conf, loaded and enabled.
  wifi_dev="$(wifi_device)"
  [ "$wifi_dev" = "$t2_dev" ] && wifi_dev=""
  render_anchor "$wifi_dev" "$t2_dev" > "$TMP/anchor"
  mkdir -p "$(dirname "$ANCHOR_FILE")"
  if ! cmp -s "$TMP/anchor" "$ANCHOR_FILE"; then
    cat "$TMP/anchor" > "$ANCHOR_FILE"
    chown root:wheel "$ANCHOR_FILE" 2>/dev/null
    chmod 644 "$ANCHOR_FILE"
    log "Wrote $ANCHOR_FILE (Wi-Fi interface: ${wifi_dev:-none found}; T2 link: ${t2_dev:-none})"
    reload=1
  fi
  if ! pf_conf_has_lines; then
    patch_pf_conf
    reload=1
  fi
  pf_rules_active || reload=1
  if [ "$reload" -eq 1 ]; then
    if out="$(pfctl -nf "$PF_CONF" 2>&1)" && pfctl -f "$PF_CONF" >/dev/null 2>&1 && pf_rules_active; then
      log "pf rules loaded"
    else
      log "pfctl said: $(printf '%s' "$out" | grep -v ALTQ | tr '\n' ' ')"
      pf_emergency
    fi
  fi
  if ! pf_enabled; then
    if pfctl -E >/dev/null 2>&1; then log "pf enabled"; else log "ERROR: could not enable pf"; fi
  fi
}

# ------------------------------------------------------------- templates ---

write_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$BIN</string>
    <string>enforce</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>WatchPaths</key>
  <array>
    <string>/Library/Preferences/SystemConfiguration/preferences.plist</string>
    <string>/private/etc/pf.conf</string>
    <string>/private/etc/pf.anchors/airgap</string>
  </array>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
EOF
}

write_profile() {
  local u1 u2 u3
  u1="$(uuidgen)"; u2="$(uuidgen)"; u3="$(uuidgen)"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadDisplayName</key>
  <string>Airgap restrictions</string>
  <key>PayloadDescription</key>
  <string>Turns off AirDrop, Handoff, AirPlay Receiver and Bluetooth. Made by airgap.sh. Remove this profile to undo.</string>
  <key>PayloadIdentifier</key>
  <string>$PROFILE_ID</string>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadScope</key>
  <string>System</string>
  <key>PayloadUUID</key>
  <string>$u1</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadDisplayName</key>
      <string>Restrictions</string>
      <key>PayloadIdentifier</key>
      <string>$PROFILE_ID.restrictions</string>
      <key>PayloadType</key>
      <string>com.apple.applicationaccess</string>
      <key>PayloadUUID</key>
      <string>$u2</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>allowAirDrop</key>
      <false/>
      <key>allowActivityContinuation</key>
      <false/>
      <key>allowAirPlayIncomingRequests</key>
      <false/>
    </dict>
    <dict>
      <key>PayloadDisplayName</key>
      <string>Bluetooth off</string>
      <key>PayloadIdentifier</key>
      <string>$PROFILE_ID.bluetooth</string>
      <key>PayloadType</key>
      <string>com.apple.ManagedClient.preferences</string>
      <key>PayloadUUID</key>
      <string>$u3</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>PayloadContent</key>
      <dict>
        <key>com.apple.MCXBluetooth</key>
        <dict>
          <key>Forced</key>
          <array>
            <dict>
              <key>mcx_preference_settings</key>
              <dict>
                <key>DisableBluetooth</key>
                <true/>
              </dict>
            </dict>
          </array>
        </dict>
      </dict>
    </dict>
  </array>
</dict>
</plist>
EOF
}

# Reads a managed (profile) setting the same way the DISA STIG checks do.
managed_pref() {
  osascript -l JavaScript -e "\$.NSUserDefaults.alloc.initWithSuiteName('$1').objectForKey('$2').js" 2>/dev/null
}

record_state() {
  local svc port dev state v6
  list_services > "$TMP/services0"
  while IFS="$TAB" read -r svc port dev state <&3; do
    v6="-"
    [ "$dev" != "-" ] && v6="$(ipv6_state "$svc")"
    printf '%s\t%s\t%s\n' "$svc" "$state" "$v6"
  done 3< "$TMP/services0"
}

# -------------------------------------------------------------- commands ---

cmd_install() {
  need_root install
  [ "$(uname -s)" = "Darwin" ] || die "this script is for macOS"
  local user self line profile_done n

  user="$(target_user)"

  say "==> Saving current network settings (used by uninstall)"
  mkdir -p "$APP_DIR"
  chown root:wheel "$APP_DIR" 2>/dev/null
  chmod 755 "$APP_DIR"
  if [ -f "$STATE" ]; then
    say "    already saved by an earlier install, keeping that copy"
  else
    record_state > "$STATE"
    chmod 644 "$STATE"
  fi

  say "==> Installing to $APP_DIR"
  self="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
  [ "$self" = "$BIN" ] || cp "$self" "$BIN" || die "could not copy the script to $BIN"
  chown root:wheel "$BIN" 2>/dev/null
  chmod 755 "$BIN"
  touch "$LOG"
  chmod 644 "$LOG"

  # Wi-Fi has to stay usable, so switch its network service back on if it was off.
  line="$(list_services | awk -F'\t' '$2 == "Wi-Fi" || $2 == "AirPort" { print; exit }')"
  if [ -n "$line" ] && [ "$(printf '%s' "$line" | cut -f4)" = "Disabled" ]; then
    networksetup -setnetworkserviceenabled "$(printf '%s' "$line" | cut -f1)" on &&
      say "    Wi-Fi network service switched back on"
  fi

  say "==> Locking the network down (pf firewall, IPv6, other network services)"
  enforce | tee -a "$LOG" | sed 's/^/    /'

  say "==> Starting the background enforcer (LaunchDaemon $LABEL)"
  write_plist > "$PLIST"
  chown root:wheel "$PLIST" 2>/dev/null
  chmod 644 "$PLIST"
  launchctl bootout system "$PLIST" >/dev/null 2>&1 && sleep 1
  launchctl enable "system/$LABEL" >/dev/null 2>&1
  launchctl bootstrap system "$PLIST" ||
    say "    WARNING: could not start it now; it will start at the next boot"

  say "==> Application Firewall: on, block all incoming, stealth mode"
  "$FW" --setglobalstate on >/dev/null 2>&1
  "$FW" --setblockall on >/dev/null 2>&1
  "$FW" --setstealthmode on >/dev/null 2>&1

  say "==> Bluetooth off"
  defaults write /Library/Preferences/com.apple.Bluetooth ControllerPowerState -int 0
  # The Bluetooth daemon is "blued" on Catalina and "bluetoothd" from Big Sur on.
  killall -HUP bluetoothd blued >/dev/null 2>&1

  if [ -n "$user" ]; then
    say "==> AirDrop and Handoff off for $user"
    as_user "$user" defaults write com.apple.NetworkBrowser DisableAirDrop -bool YES
    as_user "$user" defaults write com.apple.sharingd DiscoverableMode -string "Off"
    as_user "$user" defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool NO
    as_user "$user" defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool NO
  fi

  say "==> Restrictions profile"
  write_profile > "$PROFILE"
  chmod 644 "$PROFILE"
  plutil -lint "$PROFILE" >/dev/null 2>&1 || say "    WARNING: the profile did not pass plutil -lint"
  profile_done=0
  if [ "$OS_MAJOR" -lt 11 ]; then
    # Catalina and earlier still allow installing a profile from the command line.
    if profiles install -path "$PROFILE" >/dev/null 2>&1 || profiles -I -F "$PROFILE" >/dev/null 2>&1; then
      profile_done=1
      say "    installed"
    else
      say "    could not install it from the command line; opening it for you instead"
    fi
  fi
  if [ "$profile_done" -eq 0 ] && [ -n "$user" ]; then
    as_user "$user" open "$PROFILE" >/dev/null 2>&1
    sleep 1
    as_user "$user" open "x-apple.systempreferences:com.apple.preferences.configurationprofiles" >/dev/null 2>&1
  fi

  n=0
  say ""
  say "Done. Left for you to do:"
  if [ "$profile_done" -eq 0 ]; then
    n=$((n + 1))
    say "  $n. Approve the profile: $PROFILES_PANE"
    say "     > Airgap restrictions > Install. If it is not listed, double-click this file:"
    say "     $PROFILE"
  fi
  if has_accessory_setting; then
    n=$((n + 1))
    say "  $n. $SETTINGS > Privacy & Security > Accessories:"
    say "     set 'Allow accessories to connect' to 'Always ask'."
  fi
  n=$((n + 1))
  say "  $n. Use a standard (non-admin) account day to day, so none of this can be"
  say "     undone without the admin password."
  if [ -n "$user" ] && is_admin "$user"; then
    say "     ('$user' is an admin account right now.)"
  fi
  if [ "$OS_MAJOR" -eq 10 ]; then
    n=$((n + 1))
    say "  $n. This Mac runs macOS $OS_VER, which stopped getting security updates in 2022."
    say "     With Wi-Fi in use, that is now the biggest risk left: update macOS if this"
    say "     Mac supports a newer version, and re-run this script afterwards."
  fi
  say ""
  say "FileVault: $(fdesetup status 2>/dev/null | head -n 1)"
  say ""
  say "Check: sudo bash \"$BIN\" status"
  say "Undo:  sudo bash \"$BIN\" uninstall"
  say "Log:   $LOG"
}

cmd_status() {
  need_root status
  local svc port dev state v6 user t2

  say "pf firewall:  $(pfctl -s info 2>/dev/null | awk '/^Status:/ { print $2; exit }')"
  if pfctl -sr 2>/dev/null | grep -qF "$ANCHOR_LINE"; then
    say "airgap rules (active):"
  else
    say "airgap rules: WARNING, not hooked into the active pf ruleset"
  fi
  pfctl -a "$ANCHOR" -sr 2>/dev/null | sed 's/^/    /'
  if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    say "Enforcer:     running"
  else
    say "Enforcer:     NOT loaded"
  fi

  say ""
  say "Network services:"
  list_services > "$TMP/services"
  while IFS="$TAB" read -r svc port dev state <&3; do
    v6="-"
    [ "$dev" != "-" ] && v6="$(ipv6_state "$svc")"
    printf '    %-30s %-9s IPv6: %-10s %s\n' "$svc" "$state" "$v6" "$dev"
  done 3< "$TMP/services"

  say ""
  say "IPv6 addresses outside loopback (pf drops IPv6 on all of them except the T2 link):"
  ifconfig 2>/dev/null | awk '
    /^[a-z0-9]+: / { i = $1; sub(/:$/, "", i) }
    /^[ \t]+inet6 / && i != "lo0" { print "    " i "  " $2; n++ }
    END { if (!n) print "    none" }'
  t2="$(t2_device)"
  if [ -n "$t2" ]; then
    say "T2 chip link: $t2 (left open; it only connects macOS to the T2 chip inside the Mac)"
  fi

  say ""
  if { profiles list -all 2>/dev/null; profiles -P 2>/dev/null; } | grep -qF "$PROFILE_ID"; then
    say "Restrictions profile:          installed"
  else
    say "Restrictions profile:          NOT installed (approve it in $PROFILES_PANE)"
  fi
  if [ "$(managed_pref com.apple.applicationaccess allowAirDrop)" = "false" ]; then
    say "AirDrop blocked by profile:    yes"
  else
    say "AirDrop blocked by profile:    no"
  fi
  if [ "$(managed_pref com.apple.MCXBluetooth DisableBluetooth)" = "true" ]; then
    say "Bluetooth blocked by profile:  yes"
  else
    say "Bluetooth blocked by profile:  no"
  fi
  say "Application Firewall:          $("$FW" --getglobalstate 2>/dev/null | head -n 1)"
  say "                               $("$FW" --getblockall 2>/dev/null | head -n 1)"
  say "                               $("$FW" --getstealthmode 2>/dev/null | head -n 1)"
  say "FileVault:                     $(fdesetup status 2>/dev/null | head -n 1)"
  user="$(target_user)"
  if [ -n "$user" ] && is_admin "$user"; then
    say "Account:                       '$user' is an admin (a standard account is safer)"
  fi
  say "macOS:                         ${OS_VER:-unknown}"

  say ""
  say "Recent log:"
  tail -n 8 "$LOG" 2>/dev/null | sed 's/^/    /'
  say ""
  say "To watch traffic with the interface and process for each packet:"
  say "    sudo tcpdump -n -k INP -i any"
  if [ -n "$t2" ]; then
    say "Packets on lo0 never leave the Mac and $t2 is the T2 chip; anything else should be Wi-Fi, IPv4 only."
  else
    say "Packets on lo0 never leave the Mac; anything else should be Wi-Fi, IPv4 only."
  fi
}

cmd_uninstall() {
  need_root uninstall
  local svc port dev state v6 user

  user="$(target_user)"

  say "==> Stopping the background enforcer"
  launchctl bootout system "$PLIST" >/dev/null 2>&1 || launchctl bootout "system/$LABEL" >/dev/null 2>&1
  rm -f "$PLIST"

  say "==> Removing the pf rules"
  if [ -f "$PF_CONF" ]; then
    strip_pf_lines < "$PF_CONF" > "$TMP/pf.conf" && cat "$TMP/pf.conf" > "$PF_CONF"
  fi
  rm -f "$ANCHOR_FILE"
  pfctl -f "$PF_CONF" >/dev/null 2>&1
  pfctl -d >/dev/null 2>&1
  say "    pf is off again (the macOS default). Copy of the original pf.conf: $PF_BACKUP"

  say "==> Restoring network services and IPv6"
  if [ -f "$STATE" ]; then
    while IFS="$TAB" read -r svc state v6 <&3; do
      [ -n "$svc" ] || continue
      if [ "$state" = "Enabled" ]; then
        networksetup -setnetworkserviceenabled "$svc" on >/dev/null 2>&1 </dev/null
      fi
      case "$v6" in
        Automatic) networksetup -setv6automatic "$svc" >/dev/null 2>&1 </dev/null ;;
        *[Ll]ink*) networksetup -setv6LinkLocal "$svc" >/dev/null 2>&1 </dev/null ;;
        -|Off) ;;
        *) say "    $svc had IPv6 set to '$v6': set that again in $SETTINGS > Network" ;;
      esac
      say "    $svc: $state, IPv6 $v6"
    done 3< "$STATE"
    list_services > "$TMP/services"
    while IFS="$TAB" read -r svc port dev state <&3; do
      if [ "$state" = "Disabled" ] && ! cut -f1 "$STATE" | grep -qxF "$svc"; then
        say "    $svc was added after install and is still disabled (turn it on in $SETTINGS > Network if you want it)"
      fi
    done 3< "$TMP/services"
  else
    say "    no saved settings found: turn services and IPv6 back on in $SETTINGS > Network"
  fi

  say "==> Removing the restrictions profile"
  if profiles remove -identifier "$PROFILE_ID" >/dev/null 2>&1 || profiles -R -p "$PROFILE_ID" >/dev/null 2>&1; then
    say "    removed"
  else
    say "    not found; if it is still listed, remove it in $PROFILES_PANE"
  fi

  say "==> Bluetooth back on"
  defaults write /Library/Preferences/com.apple.Bluetooth ControllerPowerState -int 1
  killall -HUP bluetoothd blued >/dev/null 2>&1

  if [ -n "$user" ]; then
    say "==> AirDrop and Handoff back to defaults for $user"
    as_user "$user" defaults delete com.apple.NetworkBrowser DisableAirDrop >/dev/null 2>&1
    as_user "$user" defaults write com.apple.sharingd DiscoverableMode -string "Contacts Only" >/dev/null 2>&1
    as_user "$user" defaults -currentHost delete com.apple.coreservices.useractivityd ActivityAdvertisingAllowed >/dev/null 2>&1
    as_user "$user" defaults -currentHost delete com.apple.coreservices.useractivityd ActivityReceivingAllowed >/dev/null 2>&1
  fi

  rm -rf "$APP_DIR"

  say ""
  say "Undone. Left on purpose: the Application Firewall (still on; turn it off in"
  say "$FIREWALL_PANE if you want)."
  say "Log out and back in so the AirDrop and Handoff changes show up everywhere."
}

case "${1:-}" in
  install)   cmd_install ;;
  enforce)   need_root enforce; enforce ;;
  status)    cmd_status ;;
  uninstall) cmd_uninstall ;;
  *)
    say "Usage: sudo bash $0 install | status | uninstall"
    exit 1
    ;;
esac
