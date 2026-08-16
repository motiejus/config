# Pixel-level check, shared by the tool that makes a video and the tool that
# deletes the photos behind it.
#
# Counting frames and manifest rows cannot catch a video that is structurally
# perfect and visually wrong — a filter applied to the wrong frame range does
# exactly that, and did. So decode a sample of frames and compare them against
# the photos the manifest claims they came from.
#
# Calibration on this footage: a correctly encoded frame scores ~0.99, a frame
# greyed out by mistake ~0.66, and a frame from the wrong slot ~0.77.

SAMPLES=6
MIN_SSIM=0.90

verify_pixels() { # video manifest cam
  local video="$1" manifest="$2" cam="$3"
  local rows step picks sel p n=0 checked=0 slot rel frame ssim

  rows=$(grep -cP '\tphoto\t' "$manifest") || rows=0
  if [ "$rows" -eq 0 ]; then
    log "  nothing but missing frames here, no pixels to check"
    return 0
  fi
  step=$((rows / SAMPLES))
  [ "$step" -ge 1 ] || step=1
  mapfile -t picks < <(grep -P '\tphoto\t' "$manifest" | sed -n "1~${step}p" | head -n "$SAMPLES")

  for p in "${picks[@]}"; do sel="${sel:-}+eq(n\\,$(cut -f1 <<<"$p"))"; done
  rm -f "$tmp"/pix*.png
  ffmpeg -v error -y -i "$video" -vf "select=${sel#+}" -fps_mode passthrough \
    "$tmp/pix%02d.png" || die "cannot extract sample frames from $video"

  for p in "${picks[@]}"; do
    n=$((n + 1))
    slot=$(cut -f1 <<<"$p")
    rel=$(cut -f4 <<<"$p")
    frame=$(printf '%s/pix%02d.png' "$tmp" "$n")
    [ -f "$frame" ] || die "sample frame $n missing from $video"
    [ -f "$ROOT/$cam/$rel" ] || continue # stills already reaped
    # ssim reports at info level, so -v error would silently swallow it
    ssim=$({ ffmpeg -hide_banner -i "$frame" -i "$ROOT/$cam/$rel" \
      -lavfi "[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]ssim" -f null - 2>&1 ||
      true; } | { grep -o 'All:[0-9.]*' || true; } | cut -d: -f2)
    [ -n "$ssim" ] || die "cannot compare frame $slot against $rel"
    awk -v s="$ssim" -v m="$MIN_SSIM" 'BEGIN { exit !(s + 0 >= m + 0) }' ||
      die "frame $slot does not look like $rel (ssim $ssim < $MIN_SSIM)"
    checked=$((checked + 1))
  done

  if [ "$checked" -eq 0 ]; then
    log "  stills are gone, could not re-check the pixels"
  else
    log "  $checked sampled frames match their source photos"
  fi
}
