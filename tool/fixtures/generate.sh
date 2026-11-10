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

# Long enough that a cancel sent on the first progress event lands mid-flight
# even on fast hardware encoders.
ff -f lavfi -i "$VIDEO:duration=8" -f lavfi -i "$TONE:duration=8" \
  -c:v libx264 -preset veryfast -b:v 600k -pix_fmt yuv420p -c:a aac -b:a 48k \
  -movflags +faststart long_1080p.mp4

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

ff -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=1" -f lavfi -i "$TONE:duration=1" \
  -c:v libx265 -preset veryfast -b:v 1500k -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
  -x265-params "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
  -c:a aac -b:a 128k hlg_hevc.mov

ff -f lavfi -i "smptehdbars=size=1280x720:rate=30:duration=1" \
  -vf "setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc,format=yuv420p" \
  -c:v libx265 -preset veryfast -b:v 1500k -tag:v hvc1 \
  -x265-params "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
  -movflags +write_colr hlg_hevc_8bit.mp4

ff -f lavfi -i "$TONE:duration=1" -c:a aac -b:a 128k audio_only.m4a

# One second of 320x240 per container and codec the readme lists, so the
# format matrix test stays cheap. Video only, except where AAC fits the
# container, so a failure points at the video path.
SMALL="testsrc2=size=320x240:rate=30:duration=1"
ff -f lavfi -i "$SMALL" -f lavfi -i "$TONE:duration=1" \
  -c:v libx264 -preset veryfast -b:v 400k -pix_fmt yuv420p -c:a aac -b:a 64k -f ipod format_h264.m4v
ff -f lavfi -i "$SMALL" -f lavfi -i "$TONE:duration=1" \
  -c:v libx264 -preset veryfast -b:v 400k -pix_fmt yuv420p -c:a aac -b:a 64k format_h264.3gp
ff -f lavfi -i "$SMALL" -f lavfi -i "$TONE:duration=1" \
  -c:v libx264 -preset veryfast -b:v 400k -pix_fmt yuv420p -c:a aac -b:a 64k format_h264.mkv
# Mono AAC at a rate the AAC encoders do not take, so re-encoding must resample.
ff -f lavfi -i "$SMALL" -f lavfi -i "sine=frequency=440:sample_rate=22050:duration=1" \
  -c:v libx264 -preset veryfast -b:v 400k -pix_fmt yuv420p -c:a aac -ar 22050 -ac 1 -b:a 48k \
  format_aac_22k.mp4
ff -f lavfi -i "$SMALL" -c:v libx265 -preset veryfast -b:v 400k -pix_fmt yuv420p -tag:v hvc1 \
  -x265-params log-level=error format_hevc.mp4
ff -f lavfi -i "$SMALL" -c:v libvpx -b:v 400k format_vp8.webm
ff -f lavfi -i "$SMALL" -c:v libvpx-vp9 -b:v 400k format_vp9.webm
ff -f lavfi -i "$SMALL" -c:v libvpx-vp9 -b:v 400k format_vp9.mp4
ff -f lavfi -i "$SMALL" -c:v libsvtav1 -b:v 400k -pix_fmt yuv420p format_av1.mp4

# AAC plus an AC-3 track, which Android, Chrome and a bare GStreamer cannot
# decode: the readable track has to be kept and the other dropped, not the
# file failed.
ff -f lavfi -i "$SMALL" -f lavfi -i "$TONE:duration=1" -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=1" \
  -map 0:v -map 1:a -map 2:a -c:v libx264 -preset veryfast -b:v 400k -pix_fmt yuv420p \
  -c:a:0 aac -b:a:0 64k -c:a:1 ac3 -b:a:1 96k mixed_audio_tracks.mp4

# Still images in the formats the readme lists beyond JPEG, PNG, WebP, GIF and HEIC.
ff -f lavfi -i "testsrc2=size=320x240:duration=1" -frames:v 1 -c:v bmp format.bmp
ff -f lavfi -i "testsrc2=size=320x240:duration=1" -frames:v 1 -c:v tiff -pix_fmt rgb24 -compression_algo lzw format.tiff
ff -f lavfi -i "testsrc2=size=320x240:duration=1" -frames:v 1 -c:v libsvtav1 -pix_fmt yuv420p -f avif format.avif

# screen_ios.mov and screen_android.mp4 are real screen recordings from the iOS
# simulator (`xcrun simctl io <device> recordVideo --codec=hevc`) and an
# Android emulator (`adb shell screenrecord`), trimmed to two seconds. They are
# kept as recorded because odd frame sizes, variable frame rate and extra data
# tracks are the point.

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
frames[0].save("animated.png", save_all=True, append_images=frames[1:], duration=100, loop=0)
EOF

sips -s format heic -s formatOptions 80 heic_source.png --out photo.heic >/dev/null
"$PYTHON" "$(dirname "$0")/exif.py" "$OUT"
rm heic_source.png

"$PYTHON" -c 'open("broken.jpg", "w").write("not a media file\n" * 256)'

ls -l "$OUT"
