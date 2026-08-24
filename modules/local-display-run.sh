# PiKVM local-display supervisor — the target-picking / re-render loop. Static
# half of pikvm-local-display; the nix wrapper (local-display.nix) prepends
# variable assignments for everything computed from `services.pikvm.
# localDisplay.*` (mode, fixed_connector, drm_root, mpv_exe, player_args)
# before this text, same idiom as hidmode-set.sh / hid-recover.sh.

# Is a specific connector (e.g. HDMI-A-2) currently connected?
connector_connected() {
  local s
  for s in "$drm_root"/card*-"$1"/status; do
    [ -e "$s" ] || continue
    [ "$(cat "$s" 2>/dev/null)" = "connected" ] && return 0
  done
  return 1
}

# Echo the first `connected` HDMI-A connector name (e.g. HDMI-A-1), or "".
first_connected() {
  local status dir
  for status in "$drm_root"/card*-HDMI-A-*/status; do
    [ -e "$status" ] || continue
    if [ "$(cat "$status" 2>/dev/null)" = "connected" ]; then
      dir=$(basename "$(dirname "$status")")   # e.g. card0-HDMI-A-1
      printf '%s' "${dir#card*-}"              # -> HDMI-A-1
      return 0
    fi
  done
  # nothing connected: print nothing (caller treats "" as no-output)
}

# The connector to render on right now, per mode ("" if none available).
pick_target() {
  if [ "$mode" = "fixed" ]; then
    if connector_connected "$fixed_connector"; then printf '%s' "$fixed_connector"; fi
  else
    first_connected
  fi
}

mpv_pid=""
cleanup() { if [ -n "$mpv_pid" ]; then kill "$mpv_pid" 2>/dev/null || true; fi; }
trap cleanup EXIT

while true; do
  target="$(pick_target)"
  if [ -z "$target" ]; then
    echo "pikvm-local-display: no target output for mode=$mode; waiting for hotplug" >&2
    sleep 2
    continue
  fi
  echo "pikvm-local-display: rendering on connector $target (mode=$mode)" >&2
  "$mpv_exe" --drm-connector="$target" "${player_args[@]}" &
  mpv_pid=$!
  # Re-render if our target changes underneath us (move in auto, unplug in fixed).
  while kill -0 "$mpv_pid" 2>/dev/null; do
    sleep 2
    now="$(pick_target)"
    if [ "$now" != "$target" ]; then
      echo "pikvm-local-display: target changed ($target -> ${now:-none}); re-rendering" >&2
      kill "$mpv_pid" 2>/dev/null || true
      break
    fi
  done
  wait "$mpv_pid" 2>/dev/null || true
  mpv_pid=""
  sleep 1
done
