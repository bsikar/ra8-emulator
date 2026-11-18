//! ra8_host: everything that touches the host OS (ADR 0004 section 2,
//! knowledge base article RA8EMU-A-2). Sockets and readiness, the console
//! and handle readers, camera capture backends and image decoders, and
//! file-backed media. It imports only std. Libraries below the applications
//! never import it: a component that needs host data declares an interface,
//! and the application fills it from here.
pub const app_dirs = @import("app_dirs.zig");
pub const build = @import("build/root.zig");
pub const console = @import("console.zig");
pub const disk_file = @import("disk_file.zig");
pub const folder = @import("folder.zig");
pub const history = @import("history/root.zig");
pub const pipe = @import("camera/pipe/pipe.zig");
pub const pipe_pair = @import("pipe_pair.zig");
pub const profiles = @import("profiles.zig");
pub const project = @import("project/root.zig");
pub const read = @import("read.zig");
pub const session_files = @import("session_files.zig");
pub const sock = @import("sock/sock.zig");
pub const socket_flags = @import("socket_flags.zig");
pub const stops = @import("stops.zig");
pub const tape_dir = @import("tape_dir.zig");
pub const toolchain = @import("toolchain/root.zig");
pub const win32 = @import("win32.zig");
pub const worker = @import("worker.zig");
pub const workspace = @import("workspace/workspace.zig");

/// Host camera capture backends and file formats (RA8EMU-1011).
pub const camera = struct {
    pub const always = @import("camera/webcam/always.zig");
    pub const av_delegate = @import("camera/av/delegate.zig");
    pub const av_frame = @import("camera/av/frame.zig");
    pub const av_info_plist = @import("camera/av/info_plist.zig");
    pub const av_objc = @import("camera/av/objc.zig");
    pub const av_permission = @import("camera/av/permission.zig");
    pub const av_session = @import("camera/av/session.zig");
    pub const bmp = @import("camera/bmp_decode.zig");
    pub const consent = @import("camera/webcam/consent.zig");
    pub const decoded = @import("camera/decoded_image.zig");
    pub const device = @import("camera/v4l2/device.zig");
    pub const image_file = @import("camera/image_file.zig");
    pub const mf = @import("camera/mf/abi.zig");
    pub const mf_com = @import("camera/mf/com.zig");
    pub const mf_open = @import("camera/mf/open.zig");
    pub const negotiate = @import("camera/v4l2/negotiate.zig");
    pub const pipe_frame = @import("camera/pipe/frame.zig");
    pub const pipe_input = @import("camera/pipe/input.zig");
    pub const png = @import("camera/png_decode.zig");
    pub const ppm = @import("camera/ppm_decode.zig");
    pub const privacy = @import("camera/webcam/privacy.zig");
    pub const source_open = @import("camera/source/open.zig");
    pub const source_spec = @import("camera/source/spec.zig");
    pub const stream = @import("camera/v4l2/stream.zig");
    pub const v4l2 = @import("camera/v4l2/abi.zig");
    pub const video_file = @import("camera/video_file.zig");
    pub const webcam = @import("camera/webcam/webcam.zig");
    pub const y4m = @import("camera/y4m/header.zig");
    pub const y4m_frame = @import("camera/y4m/frame.zig");
};

pub const metrics = @import("metrics/metrics.zig");

pub const target_lease = @import("target_lease.zig");
pub const targets = @import("targets.zig");

/// Authenticated probe-host framing and mutual HMAC-SHA256 handshake (RA8EMU-1287).
pub const probe_host = struct {
    pub const auth = @import("probe_host/auth.zig");
    pub const wire = @import("probe_host/wire.zig");
};

/// Onboard SEGGER J-Link discovery and identity by USB serial (RA8EMU-1287).
pub const jlink = struct {
    pub const commander = @import("jlink/commander.zig");
    pub const emu_list = @import("jlink/emu_list.zig");
    pub const identity = @import("jlink/identity.zig");
    pub const run = @import("jlink/run.zig");
    pub const uart = @import("jlink/uart.zig");
    pub const uart_linux = @import("jlink/uart/linux.zig");
    pub const uart_windows = @import("jlink/uart/windows.zig");
};
