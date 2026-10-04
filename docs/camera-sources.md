# Camera sources

`--camera-source KIND[:ARG]` picks where the emulated camera engine's pixels
come from. Every source answers in the format and size the firmware
programmed, so the firmware never knows which one it has.

- `gradient` (the default): a fixed synthetic gradient.
- `image:PATH`: a still PNG, BMP or PPM picture.
- `video:PATH[,loop]`: a Y4M clip, with the frame picked by emulated time.
- `pipe:PATH|-,WxH,FORMAT`: raw frames from a named pipe, or `-` for stdin.

## Raw frame pipe

The pipe has no header. Each frame is exactly `W * H * bytes-per-pixel`
bytes and the next one starts right after it. `FORMAT` is one of:

- `rgb24`: three bytes a pixel, R then G then B (ffmpeg `-pix_fmt rgb24`).
- `yuyv`: Y0 U Y1 V, BT.601 studio range (ffmpeg `-pix_fmt yuyv422`).
  `W` must be even.
- `rgb565`: two bytes a pixel, little-endian (ffmpeg `-pix_fmt rgb565le`).

The emulator never waits on the writer. Each capture takes what has arrived,
keeps the newest whole frame and shows it; half a frame waits for the rest.
Before the first frame the capture is black. When the writer closes, the
last frame is held and the run logs it once. One capture drains at most 64
whole frames, so a writer faster than the run cannot hold it.

Linux and macOS only for now; Windows named pipes are tracked separately.

### An mp4 file through a named pipe

```sh
mkfifo /tmp/cam.fifo
ffmpeg -re -i clip.mp4 -vf scale=640:480 -pix_fmt rgb24 -f rawvideo -y /tmp/cam.fifo &
zig-out/bin/ra8_emulator camera_capture.elf \
    --camera-source pipe:/tmp/cam.fifo,640x480,rgb24
```

`-re` paces ffmpeg at the clip's own frame rate, so the run sees the
newest frame of a live feed instead of the clip racing ahead.

### A webcam through stdin

Linux (V4L2):

```sh
ffmpeg -f v4l2 -video_size 640x480 -i /dev/video0 -pix_fmt yuyv422 -f rawvideo - |
    zig-out/bin/ra8_emulator camera_capture.elf \
        --camera-source pipe:-,640x480,yuyv
```

macOS (AVFoundation):

```sh
ffmpeg -f avfoundation -framerate 30 -video_size 640x480 -i 0 \
    -pix_fmt rgb24 -f rawvideo - |
    zig-out/bin/ra8_emulator camera_capture.elf \
        --camera-source pipe:-,640x480,rgb24
```

The emulator scales the frame to whatever size the firmware programmed, so
the pipe's size only has to match what ffmpeg writes.
