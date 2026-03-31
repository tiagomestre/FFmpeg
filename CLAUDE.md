# FFmpeg Custom Static Build

This is a fork of FFmpeg configured for a single purpose: **static binaries for converting videos, audio, and images**.

The binary is shipped as a separate executable called via subprocess from the main app. The source must be made available to comply with GPL.

## Project Goals

- Produce a fully static `ffmpeg` binary (no runtime dependency on user-installed libraries)
- Support macOS (native), Linux (native), and Windows (cross-compiled from Linux)
- Include only what's needed for format conversion — no network, no devices, no playback
- All external libraries built from source as static `.a` for consistency across platforms

## Build

```bash
# macOS (native)
./build.sh

# Linux (via Docker)
docker build -t ffmpeg-builder .
docker run --rm -v $(pwd):/ffmpeg ffmpeg-builder ./build.sh

# Windows (cross-compile via Docker)
docker run --rm -v $(pwd):/ffmpeg ffmpeg-builder ./build.sh windows
```

Output: `build_output/<target>-<arch>/bin/ffmpeg`

## Licensing

- **GPL route** — binary is GPL-licensed and can be redistributed
- No non-free libraries (no libfdk-aac) — use FFmpeg's built-in AAC encoder instead
- Source code (this repo + build instructions) must be provided to users

## Included External Libraries

| Library     | Purpose              | License |
|-------------|----------------------|---------|
| libx264     | H.264 encoding       | GPL     |
| libx265     | H.265/HEVC encoding  | GPL     |
| libvpx      | VP8/VP9              | BSD     |
| libsvtav1   | AV1 encoding (fast)  | BSD     |
| libdav1d    | AV1 decoding         | BSD     |
| libwebp     | WebP image encoding  | BSD     |
| libmp3lame  | MP3 encoding         | LGPL    |
| libopus     | Opus audio           | BSD     |
| libvorbis   | Vorbis audio         | BSD     |
| libass      | Subtitle rendering   | ISC     |
| libfreetype | Font rendering       | FTL/GPL |
| libharfbuzz | Text shaping         | MIT     |
| libfribidi  | BiDi text            | LGPL    |
| zlib        | Compression          | Zlib    |
| libiconv    | Charset conversion   | LGPL    |

FFmpeg's built-in AAC encoder is used instead of libfdk-aac to stay redistributable.

## What's Disabled

- `--disable-autodetect` + explicit disables (no GPU, no system libs auto-linked)
- `--disable-network` (no HTTP, RTMP, etc.)
- `--disable-protocols` + only `file` and `pipe` re-enabled
- `--disable-avdevice` / `--disable-indevs` / `--disable-outdevs` (no capture/playback)
- `--disable-ffplay` (no playback tool)
- `--enable-lto` (link-time optimization for smaller binary)
- `--disable-doc` / `--disable-debug`

## Architecture

This is a standard FFmpeg source tree. The only modification is removing ffprobe from the Makefile build targets (`fftools/Makefile`). Only the `ffmpeg` binary is produced.
