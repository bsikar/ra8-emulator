//! What the modelled modem says back: the AT script an answer is looked up
//! in, and the one error every command outside it gets.
//!
//! Ported from the table at the top of board_periph_modem.c on dev, with the
//! matching rule V.250 states rather than the exact byte compare dev used. A
//! command line is case-insensitive on the wire, so `at+csq` is the same
//! command as `AT+CSQ`; dev answered the lower-case form "operation not
//! supported", which is a refusal the bench would never give.
//!
//! Responses are framed the way a modem frames them: a leading CRLF, the
//! payload line, a blank line, then the final OK. `AT+CREG=1` carries the
//! unsolicited `+CREG: 1` behind its OK, the modem reporting its current
//! registration once URCs are enabled.
const std = @import("std");

/// One scripted exchange.
pub const Reply = struct {
    /// The command line as the modem reads it, without its terminator.
    command: []const u8,
    /// Exactly the bytes the modem drives back.
    response: []const u8,
};

/// The script the modelled modem answers, dev's s_k_modem_script.
pub const script = [_]Reply{
    .{ .command = "AT", .response = "\r\nOK\r\n" },
    .{ .command = "ATE0", .response = "\r\nOK\r\n" },
    .{ .command = "AT+CMEE=1", .response = "\r\nOK\r\n" },
    .{ .command = "AT+CPIN?", .response = "\r\n+CPIN: READY\r\n\r\nOK\r\n" },
    .{ .command = "AT+CSQ", .response = "\r\n+CSQ: 17,99\r\n\r\nOK\r\n" },
    .{ .command = "AT+CREG=1", .response = "\r\nOK\r\n\r\n+CREG: 1\r\n" },
    .{ .command = "AT+CREG?", .response = "\r\n+CREG: 1,1\r\n\r\nOK\r\n" },
    .{ .command = "AT+CGATT?", .response = "\r\n+CGATT: 1\r\n\r\nOK\r\n" },
};

/// What a command outside the script gets. `AT+CMEE=1` is in the script, so
/// the numeric CME form is what the demo has asked for by the time anything
/// else is refused.
pub const cme_error: []const u8 = "\r\n+CME ERROR: 4\r\n";

/// The two bytes that are not command text.
pub const control = struct {
    /// The line terminator: a modem answers on CR.
    pub const cr: u8 = '\r';
    /// Not a terminator, and not part of the line either.
    pub const lf: u8 = '\n';
};

/// The response for a completed command line, or null when the script has
/// nothing to say to it.
pub fn answerFor(command: []const u8) ?[]const u8 {
    for (&script) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.command, command)) return entry.response;
    }
    return null;
}
