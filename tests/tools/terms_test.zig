//! The terminology gate catches the old words in prose and in identifiers,
//! and leaves look-alikes alone. Test inputs spell the words in halves so
//! the gate passes over this file too.
const std = @import("std");
const terms = @import("terms");

const m = "mas" ++ "ter";
const s = "sla" ++ "ve";

test "an old word is caught in prose, in any case" {
    try std.testing.expect(terms.firstBanned("every bus " ++ m ++ " here") != null);
    try std.testing.expect(terms.firstBanned("SPI " ++ "SLA" ++ "VE mode") != null);
}

test "an old word welded into an identifier is caught" {
    try std.testing.expect(terms.firstBanned("memory.as" ++ "Mas" ++ "ter(.cpu0)") != null);
    try std.testing.expect(terms.firstBanned("const " ++ s ++ "_count = 2;") != null);
}

test "pin names are whole words, split by an underscore" {
    try std.testing.expect(terms.firstBanned("drive " ++ "MI" ++ "SO" ++ "_PIN high") != null);
    try std.testing.expect(terms.firstBanned("PRE" ++ "MO" ++ "SI" ++ "X") == null);
}

test "the words we use instead pass" {
    try std.testing.expect(terms.firstBanned("a bus initiator reads CIPO while CS is low") == null);
    try std.testing.expect(terms.firstBanned("the SPI controller and its peripheral") == null);
}

test "only source and text files are read" {
    try std.testing.expect(terms.isScanned("memmap.zig"));
    try std.testing.expect(terms.isScanned("README.md"));
    try std.testing.expect(!terms.isScanned("demo.elf"));
}
