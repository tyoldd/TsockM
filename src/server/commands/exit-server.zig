const std = @import("std");
const aids = @import("aids");
const core = @import("../core/core.zig");
const cmn = aids.cmn;
const Protocol = aids.Protocol;
const net = std.net;
const Command = core.Command;
const SharedData = core.SharedData;
const Peer = core.Peer;

pub fn executor(_: ?[]const u8, _: ?*SharedData) void {
    std.debug.print("Exiting server ...\n", .{});
    std.posix.exit(0);
}

pub const COMMAND = Command{
    .executor = executor,
};
