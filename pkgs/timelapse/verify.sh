# Pixel-level check, used by the tool that deletes the photos behind a video.
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
  local rows picks slots sel p n=0 checked=0 got matched rel frame ssim

  { grep -P '\tphoto\t' "$manifest" || true; } >"$tmp/photorows"
  rows=$(wc -l <"$tmp/photorows")
  if [ "$rows" -eq 0 ]; then
    log "  nothing but missing frames here, no pixels to check"
    return 0
  fi
  # Spread evenly from the first photo row to the last. A fixed stride cannot
  # reach the tail — the last sixth of every period — and a random sample cannot
  # be reproduced, which matters when the run that fails is the one that would
  # otherwise have deleted the photos.
  mapfile -t picks < <(awk -v n="$rows" -v k="$SAMPLES" \
    'BEGIN { for (i = 0; i < k; i++) want[1 + int(i * (n - 1) / (k - 1))] = 1 } NR in want' \
    "$tmp/photorows")

  slots=()
  for p in "${picks[@]}"; do
    slots+=("$(cut -f1 <<<"$p")")
    sel="${sel:-}+eq(n\\,${slots[-1]})"
  done
  rm -f "$tmp"/pix*.png
  ffmpeg -y -i "$video" -map 0:v:0 -vf "select=${sel#+}" -fps_mode passthrough \
    "$tmp/pix%02d.png" 2>"$tmp/extract.log" ||
    die "cannot extract sample frames from $video: $(tail -2 "$tmp/extract.log")"

  # One real file per sampled slot, in ascending slot order, which is what pairs
  # them up below. On 2025-03 this came up short on both cameras and no cause has
  # been found: the same extraction reproduces nowhere, at any scale or geometry.
  # So report the parts instead of guessing — how many frames the filter matched
  # separates losing them on the way out from never matching them at all.
  got=$(find "$tmp" -maxdepth 1 -type f -name 'pix*.png' | wc -l)
  [ "$got" -eq "${#picks[@]}" ] || {
    matched=$({ ffmpeg -hide_banner -i "$video" -vf "select=${sel#+}" -f null - 2>&1 ||
      true; } | { grep -o 'frame= *[0-9]*' || true; } | tail -1 | tr -dc 0-9)
    die "$(basename "$video"): asked for ${#picks[@]} frames at slots ${slots[*]},
  the filter matched ${matched:-?} and ffmpeg wrote $got. Nothing was deleted.
  $(tail -2 "$tmp/extract.log")"
  }

  for p in "${picks[@]}"; do
    n=$((n + 1))
    rel=$(cut -f4 <<<"$p")
    frame=$(printf '%s/pix%02d.png' "$tmp" "$n")
    [ -f "$ROOT/$cam/$rel" ] || continue # stills already reaped
    # ssim reports at info level, so -v error would silently swallow it
    ssim=$({ ffmpeg -hide_banner -i "$frame" -i "$ROOT/$cam/$rel" \
      -lavfi "[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]ssim" -f null - 2>&1 ||
      true; } | { grep -o 'All:[0-9.]*' || true; } | cut -d: -f2)
    [ -n "$ssim" ] || die "cannot compare frame ${slots[n - 1]} against $rel"
    awk -v s="$ssim" -v m="$MIN_SSIM" 'BEGIN { exit !(s + 0 >= m + 0) }' ||
      die "frame ${slots[n - 1]} does not look like $rel (ssim $ssim < $MIN_SSIM)"
    checked=$((checked + 1))
  done

  if [ "$checked" -eq 0 ]; then
    log "  stills are gone, could not re-check the pixels"
  else
    log "  $checked sampled frames match their source photos"
  fi
}
