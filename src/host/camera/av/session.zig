//! Opens and closes the macOS webcam (RA8EMU-502) over the Objective-C
//! runtime: device N of devicesWithMediaType:video, its input, a session
//! at the 640x480 preset, and a video data output asking for 640x480 2vuy
//! cropped to fill, that drops late frames and hands each sample to Ra8CaptureDelegate on
//! its own dispatch queue. The delegate feeds the sink attached here. Any
//! step that fails releases what was made and detaches the sink.
const objc = @import("objc.zig");
const delegate = @import("delegate.zig");
const frame = @import("frame.zig");

const Id = objc.Id;

/// The AVFoundation and CoreVideo constants and the libdispatch call.
pub const Symbols = struct {
    video: Id, // AVMediaTypeVideo
    preset: Id, // AVCaptureSessionPreset640x480
    format_key: Id, // kCVPixelBufferPixelFormatTypeKey
    width_key: Id, // kCVPixelBufferWidthKey
    height_key: Id, // kCVPixelBufferHeightKey
    scaling_key: Id, // AVVideoScalingModeKey
    aspect_fill: Id, // AVVideoScalingModeResizeAspectFill
    queue_create: *const fn ([*:0]const u8, Id) callconv(.c) Id,
};

pub const width = 640;
pub const height = 480;
pub const queue_label = "ra8.camera";

pub const OpenError = error{ NoDevice, NoInput, NoSession, NoOutput };

pub const Session = struct {
    rt: objc.Runtime,
    input: Id = null,
    session: Id = null,
    output: Id = null,
    sink_object: Id = null,
    queue: Id = null,
    running: bool = false,

    /// Stops the capture, detaches the sink, and releases every object.
    pub fn close(self: *Session) void {
        if (self.running) objc.send0(self.rt, void, self.session, "stopRunning");
        self.running = false;
        delegate.detach();
        for ([_]*Id{ &self.output, &self.input, &self.sink_object, &self.session, &self.queue }) |slot| {
            if (slot.*) |object| objc.send0(self.rt, void, object, "release");
            slot.* = null;
        }
    }
};

/// Device `index` running into `sink`.
pub fn open(rt: objc.Runtime, syms: Symbols, index: usize, sink: *delegate.Sink) OpenError!Session {
    var self: Session = .{ .rt = rt };
    errdefer self.close();
    self.input = try input(rt, syms, index);
    self.session = objc.new(rt, "AVCaptureSession") orelse return error.NoSession;
    if (objc.send1(rt, u8, self.session, "canSetSessionPreset:", syms.preset) != 0)
        objc.send1(rt, void, self.session, "setSessionPreset:", syms.preset);
    if (objc.send1(rt, u8, self.session, "canAddInput:", self.input) == 0) return error.NoInput;
    objc.send1(rt, void, self.session, "addInput:", self.input);
    try output(&self, syms, sink);
    objc.send0(rt, void, self.session, "startRunning");
    self.running = true;
    return self;
}

/// An owned (retained) input for device `index`.
fn input(rt: objc.Runtime, syms: Symbols, index: usize) OpenError!Id {
    const devices = objc.send1(rt, Id, rt.class("AVCaptureDevice"), "devicesWithMediaType:", syms.video) orelse return error.NoDevice;
    if (index >= objc.send0(rt, usize, devices, "count")) return error.NoDevice;
    const device = objc.send1(rt, Id, devices, "objectAtIndex:", index) orelse return error.NoDevice;
    const made = objc.send2(rt, Id, rt.class("AVCaptureDeviceInput"), "deviceInputWithDevice:error:", device, @as(Id, null)) orelse return error.NoInput;
    return objc.send0(rt, Id, made, "retain");
}

fn output(self: *Session, syms: Symbols, sink: *delegate.Sink) OpenError!void {
    const rt = self.rt;
    self.output = objc.new(rt, "AVCaptureVideoDataOutput") orelse return error.NoOutput;
    // A camera with no 640x480 preset (a 1080p FaceTime camera) still
    // sends 640x480, cropped to 4:3 as a VGA sensor sees it: the output
    // scales to the size it is asked for, and the Mailbox takes no other
    // (RA8EMU-727).
    const settings = objc.send1(rt, Id, rt.class("NSMutableDictionary"), "dictionaryWithCapacity:", @as(usize, 4)) orelse return error.NoOutput;
    for ([_]struct { Id, u32 }{ .{ syms.format_key, frame.cv_2vuy }, .{ syms.width_key, width }, .{ syms.height_key, height } }) |entry| {
        const number = objc.send1(rt, Id, rt.class("NSNumber"), "numberWithUnsignedInt:", entry[1]) orelse return error.NoOutput;
        objc.send2(rt, void, settings, "setObject:forKey:", number, entry[0]);
    }
    objc.send2(rt, void, settings, "setObject:forKey:", syms.aspect_fill, syms.scaling_key);
    objc.send1(rt, void, self.output, "setVideoSettings:", settings);
    objc.send1(rt, void, self.output, "setAlwaysDiscardsLateVideoFrames:", @as(u8, 1));
    const cls = objc.delegateClass(rt) orelse return error.NoOutput;
    const made = objc.send0(rt, Id, cls, "alloc") orelse return error.NoOutput;
    self.sink_object = objc.send0(rt, Id, made, "init") orelse return error.NoOutput;
    self.queue = syms.queue_create(queue_label, null) orelse return error.NoOutput;
    delegate.attach(sink);
    objc.send2(rt, void, self.output, "setSampleBufferDelegate:queue:", self.sink_object, self.queue);
    if (objc.send1(rt, u8, self.session, "canAddOutput:", self.output) == 0) return error.NoOutput;
    objc.send1(rt, void, self.session, "addOutput:", self.output);
}
