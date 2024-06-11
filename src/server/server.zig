const std = @import("std");
const aids = @import("aids");
const core = @import("core/core.zig");
const ServerAction = @import("actions/actions.zig");
const Server = core.Server;
const Peer = core.Peer;
const PeerRef = core.PeerRef;
const SharedData = core.SharedData;
const Protocol = aids.Protocol;
const cmn = aids.cmn;
const TextColor = aids.TextColor;
const Logging = aids.Logging;
const net = std.net;
const mem = std.mem;
const print = std.debug.print;

const str_allocator = std.heap.page_allocator;

pub fn peerRefFromUsername(peer_pool: *std.ArrayList(Peer), username: []const u8) ?PeerRef {
    // O(n)
    for (peer_pool.items, 0..) |peer, i| {
        if (mem.eql(u8, peer.username, username)) {
            return .{ .peer = peer, .ref_id = i };
        }
    }
    return null;
}

/// I am thread
fn listener(
    sd: *SharedData,
) !void {
    while (!sd.should_exit) {
        const conn = try sd.server.net_server.accept();

        const stream = conn.stream;

        var buf: [256]u8 = undefined;
        _ = try stream.read(&buf);
        const recv = mem.sliceTo(&buf, 170);

        // Handle communication request
        var protocol = Protocol.protocolFromStr(recv); // parse protocol from recieved bytes
        protocol.dump(sd.server.log_level);

        const opt_action = sd.server.Actioner.get(core.parseAct(protocol.action));
        if (opt_action) |act| {
            switch (protocol.type) {
                // TODO: better handling of optional types
                .REQ => act.collect.?.request(conn, sd, protocol),
                .RES => act.collect.?.response(sd, protocol),
                .ERR => act.collect.?.err(),
                else => {
                    std.log.err("`therad::listener`: unknown protocol type!", .{});
                    unreachable;
                }
            }
        }
    }
    print("Ending `listener`\n", .{});
}

fn printUsage() void {
    print("COMMANDS:\n", .{});
    print("    * :c .............................. clear screen\n", .{});
    print("    * :info ........................... print server statiistics\n", .{});
    print("    * :exit ........................... terminate server\n", .{});
    print("    * :help ........................... print server commands\n", .{});
    print("    * :clean-pool ..................... removes dead peers\n", .{});
    print("    * :list | :ls  .................... list all active peers\n", .{});
    print("    * :ping <peer_id> | all ........... ping peer/s and update its/their life status\n", .{});
    print("    * :kill <peer_id> | all ........... kill peer/s\n", .{});
}

fn extractCommandValue(cs: []const u8, cmd: []const u8) []const u8 {
    var splits = mem.split(u8, cs, cmd);
    _ = splits.next().?; // the `:msg` part
    const val = mem.trimLeft(u8, splits.next().?, " \n");
    if (val.len <= 0) {
        std.log.err("missing action value", .{});
        printUsage();
    }
    return val;
}


/// i am a thread
fn commander(
    sd: *SharedData,
    server_cmds: *std.StringHashMap(Command),
) !void {
    while (!sd.should_exit) {
        // read for command
        var buf: [256]u8 = undefined;
        const stdin = std.io.getStdIn().reader();
        if (try stdin.readUntilDelimiterOrEof(buf[0..], '\n')) |user_input| {
            // Handle different commands
            var splits = mem.splitScalar(u8, user_input, ' ');
            if (splits.next()) |ui| {
                if (server_cmds.get(ui)) |cmd| {
                    cmd(user_input, sd);
                } else {
                    print("Unknown command: `{s}`\n", .{user_input});
                    printUsage();
                }
            }
        } else {
            std.log.err("something went wrong when reading stdin!", .{});
            std.posix.exit(1);
        }
    }
    print("Thread `run_cmd` finished\n", .{});
}

/// this is a thread
fn polizei(sd: *SharedData) !void {
    var start_t = try std.time.Instant.now();
    var lock = false;
    while (!sd.should_exit) {
        const now_t = try std.time.Instant.now();
        const dt  = now_t.since(start_t) / std.time.ns_per_ms;
        if (dt == 2000 and !lock) {
            if (sd.server.Actioner.get(core.Act.COMM)) |act| {
                act.transmit.?.request(Protocol.TransmitionMode.BROADCAST, sd, "");
            }
            lock = true;
        }
        if (dt == 3000 and lock) {
            if (sd.server.Actioner.get(core.Act.NTFY_KILL)) |act| {
                act.transmit.?.request(Protocol.TransmitionMode.BROADCAST, sd, "");
            }
            lock = false;
        }
        if (dt == 4000 and !lock) {
            if (sd.server.Actioner.get(core.Act.CLEAN_PEER_POOL)) |act| {
                act.internal.?(sd);
            }
            lock = false;
            start_t = try std.time.Instant.now();
        }
    }
}

const Command = *const fn ([]const u8, *SharedData) void;

const ServerCommand = struct {
    pub fn exitServer(cmd: []const u8, sd: *SharedData) void {
        _ = cmd;
        _ = sd;
        print("Exiting server ...\n", .{});
        std.posix.exit(0);
    }
    pub fn printServerStats(cmd: []const u8, sd: *SharedData) void {
        _ = cmd;
        const now = std.time.Instant.now() catch |err| {
            std.log.err("`printServerStats`: {any}", .{err});
            std.posix.exit(1);
        };
        const dt = now.since(sd.server.start_time) / std.time.ns_per_ms / 1000;
        print("==================================================\n", .{});
        print("Server status\n", .{});
        print("--------------------------------------------------\n", .{});
        print("peers connected: {d}\n", .{sd.peer_pool.items.len});
        print("uptime: {d:.3}s\n", .{dt});
        print("address: {s}\n", .{ sd.server.address_str });
        print("==================================================\n", .{});
    }
    pub fn listActivePeers(cmd: []const u8, sd: *SharedData) void {
        _ = cmd;
        if (sd.peer_pool.items.len == 0) {
            print("Peer list: []\n", .{});
        } else {
            print("Peer list ({d}):\n", .{sd.peer_pool.items.len});
            for (sd.peer_pool.items[0..]) |peer| {
                peer.dump();
            }
        }
    }
    pub fn killPeers(cmd: []const u8, sd: *SharedData) void {
        var split = mem.splitBackwardsScalar(u8, cmd, ' ');
        if (split.next()) |arg| {
            if (mem.eql(u8, arg, cmd)) {
                std.log.err("missing argument", .{});
                printUsage();
                return;
            }
            if (mem.eql(u8, arg, "all")) {
                if (sd.server.Actioner.get(core.Act.COMM_END)) |act| {
                    act.transmit.?.request(Protocol.TransmitionMode.BROADCAST, sd, "");
                }
            } else {
                const opt_peer_ref = core.PeerCore.peerRefFromId(sd.peer_pool, arg);
                if (opt_peer_ref) |peer_ref| {
                    if (sd.server.Actioner.get(core.Act.COMM_END)) |act| {
                        const id = std.fmt.allocPrint(str_allocator, "{d}", .{peer_ref.ref_id}) catch |err| {
                            std.log.err("killPeers: {any}", .{err});
                            return;
                        };
                        defer str_allocator.free(id);
                        act.transmit.?.request(Protocol.TransmitionMode.UNICAST, sd, id);
                    }
                }
            }
        }
    }
    fn ping(cmd: []const u8, sd: *SharedData) void {
        var split = mem.splitBackwardsScalar(u8, cmd, ' ');
        if (split.next()) |arg| {
            if (mem.eql(u8, arg, cmd)) {
                std.log.err("missing argument", .{});
                printUsage();
                return;
            }
            if (mem.eql(u8, arg, "all")) {
                for (sd.peer_pool.items, 0..) |peer, pid| {
                    const reqp = Protocol{
                        .type = Protocol.Typ.REQ, // type
                        .action = Protocol.Act.COMM, // action
                        .status_code = Protocol.StatusCode.OK, // status_code
                        .sender_id = "server", // sender_id
                        .src = sd.server.address_str, // src_address
                        .dst = peer.commAddressAsStr(), // dst address
                        .body = "check?", // body
                    };
                    reqp.dump(Logging.Level.DEV);
                    // TODO: I don't know why but i must send 2 requests to determine the status of the stream
                    _ = Protocol.transmit(peer.stream(), reqp);
                    const status = Protocol.transmit(peer.stream(), reqp);
                    if (status == 1) {
                        // TODO: Put htis into sd ??
                        sd.peer_pool.items[pid].alive = false;
                    } 
                }
            } else {
                var found: bool = false;
                for (sd.peer_pool.items, 0..) |peer, pid| {
                    if (mem.eql(u8, peer.id, arg)) {
                        const reqp = Protocol{
                            .type = Protocol.Typ.REQ, // type
                            .action = Protocol.Act.COMM, // action
                            .status_code = Protocol.StatusCode.OK, // status_code
                            .sender_id = "server", // sender_id
                            .src = sd.server.address_str, // src_address
                            .dst = peer.commAddressAsStr(), // dst address
                            .body = "check?", // body
                        };
                        reqp.dump(Logging.Level.DEV);
                        // TODO: I don't know why but i must send 2 requests to determine the status of the stream
                        _ = Protocol.transmit(peer.stream(), reqp);
                        const status = Protocol.transmit(peer.stream(), reqp);
                        if (status == 1) {
                            // TODO: Put htis into sd ??
                            sd.peer_pool.items[pid].alive = false;
                        } 
                        found = true;
                    }
                }
                if (!found) {
                    print("Peer with id `{s}` was not found!\n", .{arg});
                }
            }
        }
    }
    pub fn clearScreen(cmd: []const u8, sd: *SharedData) void {
        _ = cmd;
        cmn.screenClear() catch |err| {
            print("`clearScreen`: {any}\n", .{err});
        };
        print("Server running on `" ++ TextColor.paint_green("{s}") ++ "`\n", .{sd.server.address_str});
    }
    pub fn cleanPool(cmd: []const u8, sd: *SharedData) void {
        _ = cmd;
        var pp_len: usize = sd.peer_pool.items.len;
        while (pp_len > 0) {
            pp_len -= 1;
            const p = sd.peer_pool.items[pp_len];
            if (p.alive == false) {
                _ = sd.peerRemove(pp_len);
            }
        }
    }
    pub fn printProgramUsage(cmd: []const u8, sd: *SharedData) void {
        _ = cmd;
        _ = sd;
        printUsage();
    }
};

pub fn start(hostname: []const u8, port: u16, log_level: Logging.Level) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();

    var server = Server.init(gpa_allocator, hostname, port, log_level);
    defer server.deinit();

    server.Actioner.add(core.Act.COMM, ServerAction.COMM_ACTION);
    server.Actioner.add(core.Act.COMM_END, ServerAction.COMM_END_ACTION);
    server.Actioner.add(core.Act.MSG, ServerAction.MSG_ACTION);
    server.Actioner.add(core.Act.GET_PEER, ServerAction.GET_PEER_ACTION);
    server.Actioner.add(core.Act.NTFY_KILL, ServerAction.NTFY_KILL_ACTION);
    server.Actioner.add(core.Act.NONE, ServerAction.BAD_REQUEST_ACTION);
    server.Actioner.add(core.Act.CLEAN_PEER_POOL, ServerAction.CLEAN_PEER_POOL_ACTION);

    var server_cmds = std.StringHashMap(Command).init(gpa_allocator);
    errdefer server_cmds.deinit();
    defer server_cmds.deinit();

    _ = try server_cmds.put(":exit"      , ServerCommand.exitServer);
    _ = try server_cmds.put(":info"      , ServerCommand.printServerStats);
    _ = try server_cmds.put(":list"      , ServerCommand.listActivePeers);
    _ = try server_cmds.put(":ls"        , ServerCommand.listActivePeers);
    _ = try server_cmds.put(":kill"      , ServerCommand.killPeers);
    _ = try server_cmds.put(":ping"      , ServerCommand.ping);
    _ = try server_cmds.put(":c"         , ServerCommand.clearScreen);
    _ = try server_cmds.put(":clean-pool", ServerCommand.cleanPool);
    _ = try server_cmds.put(":help"      , ServerCommand.printProgramUsage);

    var peer_pool = std.ArrayList(Peer).init(gpa_allocator);
    defer peer_pool.deinit();

    try cmn.screenClear();
    server.start();

    var thread_pool: [3]std.Thread = undefined;
    var sd = SharedData{
        .m = std.Thread.Mutex{},
        .should_exit = false,
        .peer_pool = &peer_pool,
        .server = server,
    };
    {
        thread_pool[0] = try std.Thread.spawn(.{}, listener, .{ &sd });
        thread_pool[1] = try std.Thread.spawn(.{}, commander, .{ &sd, &server_cmds });
        thread_pool[2] = try std.Thread.spawn(.{}, polizei, .{ &sd });
    }
    defer for(thread_pool) |thr| thr.join();
}
