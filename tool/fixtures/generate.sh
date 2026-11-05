#!/bin/bash
# Regenerates the integration test fixtures in example/integration_test/fixtures.
# Needs ffmpeg with libx264, libx265 and libmp3lame, Python 3 with Pillow, and
# macOS sips for HEIC.
set -euo pipefail

PYTHON=${PYTHON:-python3}
OUT="$(cd "$(dirname "$0")/../.." && pwd)/example/integration_test/fixtures"
mkdir -p "$OUT"
cd "$OUT"

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
VIDEO="testsrc2=size=1920x1080:rate=30"
TONE="sine=frequency=440:sample_rate=48000"

ff -f lavfi -i "$VIDEO:duration=2" -f lavfi -i "$TONE:duration=2" \
  -c:v libx264 -preset veryfast -b:v 2500k -pix_fmt yuv420p -c:a aac -b:a 128k \
  -movflags +faststart h264_aac_1080p.mp4

ff -display_rotation:v 90 -i h264_aac_1080p.mp4 -t 1 -c copy h264_rotated_90.mp4

ff -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=1" -f lavfi -i "$TONE:duration=1" \
  -c:v libx265 -preset veryfast -b:v 1500k -pix_fmt yuv420p -tag:v hvc1 -c:a aac -b:a 128k \
  -x265-params log-level=error hevc_aac_720p.mov

ff -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=1" -f lavfi -i "$TONE:duration=1" \
  -f lavfi -i "sine=frequency=880:sample_rate=44100:duration=1" \
  -map 0:v -map 1:a -map 2:a -c:v libx264 -preset veryfast -b:v 1500k -pix_fmt yuv420p \
  -c:a aac -b:a 96k two_audio_tracks.mp4

ff -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=1" -f lavfi -i "$TONE:duration=1" \
  -c:v libx264 -preset veryfast -b:v 1500k -pix_fmt yuv420p -c:a libmp3lame -b:a 128k \
  mp3_audio.mp4

ff -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=1" \
  -c:v libx265 -preset veryfast -b:v 1500k -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -x265-params "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
  hdr10_hevc.mp4

ff -f lavfi -i "$TONE:duration=1" -c:a aac -b:a 128k audio_only.m4a

"$PYTHON" - <<'EOF'
from PIL import Image, ImageDraw

def scene(size, mode="RGB"):
    image = Image.new(mode, size, (30, 90, 160, 255) if mode == "RGBA" else (30, 90, 160))
    draw = ImageDraw.Draw(image)
    w, h = size
    for i in range(0, w, 40):
        draw.line([(i, 0), (w - i, h)], fill=(240, 200, 40, 255), width=6)
    draw.rectangle([w // 10, h // 10, w // 3, h // 3], fill=(220, 40, 60, 255))
    return image

exif = Image.Exif()
exif[0x0112] = 6
scene((1600, 1200)).save("photo_exif_rotated.jpg", quality=90, exif=exif)

transparent = scene((1200, 800), "RGBA")
transparent.putalpha(160)
transparent.save("alpha.png")

scene((1600, 1200)).save("photo.webp", quality=90)
scene((1600, 1200)).save("heic_source.png")

frames = [scene((320, 240)).rotate(angle) for angle in (0, 10, 20)]
frames[0].save("animated.webp", save_all=True, append_images=frames[1:], duration=100, loop=0)
frames[0].save("animated.gif", save_all=True, append_images=frames[1:], duration=100, loop=0)
EOF

sips -s format heic -s formatOptions 80 heic_source.png --out photo.heic >/dev/null
rm heic_source.png

"$PYTHON" -c 'open("broken.jpg", "w").write("not a media file\n" * 256)'

ls -l "$OUT"
