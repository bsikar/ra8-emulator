//! The application's hold on the C6's host traffic (time-travel design
//! section 11). While the debugger replays recorded history the machine is
//! the past's: host sockets are neither read into it nor written from it,
//! so asynchronous host traffic never forks and never reaches a rewound
//! machine. Held bytes wait in the host's own socket buffers and arrive in
//! their order once the run is back at the recorded end and the hold lifts.

/// Answers whether host traffic is held right now.
pub const Hold = struct {
    context: *anyopaque,
    heldFn: *const fn (*anyopaque) bool,
};
