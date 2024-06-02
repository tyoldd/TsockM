const std = @import("std");
const ptc = @import("ptc");
const cmn = @import("cmn");
const sqids = @import("sqids");
const net = std.net;
const mem = std.mem;
const print = std.debug.print;

const LOG_LEVEL = ptc.LogLevel.TINY;

const SERVER_ADDRESS = "192.168.88.145";
const SERVER_PORT = 6969;

const PEER_ID = []const u8;
const str_allocator = std.heap.page_allocator;

const Peer = struct {
    conn: net.Server.Connection,
    id: PEER_ID,
    username: PEER_ID = "",
    alive: bool = true,
    pub fn init(conn: net.Server.Connection, id: PEER_ID) Peer {
        // TODO: check for peer.id collisions
        return Peer{
            .id = id,
            .conn = conn,
        };
    }
    pub fn stream(self: @This()) net.Stream {
        return self.conn.stream;
    }
    pub fn comm_address(self: @This()) net.Address {
        return self.conn.address;
    }
};

fn peer_dump(p: Peer) void {
    print("------------------------------------\n", .{});
    print("Peer {{\n", .{});
    print("    id: `{s}`\n", .{p.id});
    print("    username: `{s}`\n", .{p.username});
    print("    comm_addr: `{any}`\n", .{p.comm_address()});
    print("    alive: `{any}`\n", .{p.alive});
    print("}}\n", .{});
    print("------------------------------------\n", .{});
}

fn peer_find_id(peer_pool: *std.ArrayList(Peer), id: PEER_ID) ?struct { peer: Peer, ref_id: usize } {
    // O(n)
    var i: usize = 0;
    for (peer_pool.items[0..]) |peer| {
        if (mem.eql(u8, peer.id, id)) {
            return .{ .peer = peer, .ref_id = i };
        }
        i += 1;
    }
    return null;
}

fn peer_find_username(peer_pool: *std.ArrayList(Peer), un: []const u8) ?struct {peer: Peer, ref_id: usize} {
    // O(n)
    var i: usize = 0;
    for (peer_pool.items[0..]) |peer| {
        if (mem.eql(u8, peer.username, un)) {
            return .{ .peer = peer, .ref_id = i };
        }
        i += 1;
    }
    return null;
}

fn peer_construct(
    conn: net.Server.Connection,
    protocol: ptc.Protocol,
) Peer {
    var rand = std.rand.DefaultPrng.init(@as(u64, @bitCast(std.time.milliTimestamp())));
    const s = sqids.Sqids.init(std.heap.page_allocator, .{ .min_length = 10 }) catch |err| {
        std.log.warn("{any}", .{err});
        std.posix.exit(1);
    };
    const id = s.encode(&.{ rand.random().int(u64), rand.random().int(u64), rand.random().int(u64) }) catch |err| {
        std.log.warn("{any}", .{err});
        std.posix.exit(1);
    };
    var peer = Peer.init(conn, id);
    const user_sig = s.encode(&.{ rand.random().int(u8), rand.random().int(u8), rand.random().int(u8) }) catch |err| {
        std.log.warn("{any}", .{err});
        std.posix.exit(1);
    };
    // DON'T EVER FORGET TO ALLOCATE MEMORY !!!!!!
    const aun = std.fmt.allocPrint(str_allocator, "{s}#{s}", .{ protocol.body, user_sig }) catch "format failed";
    peer.username = aun;
    peer_dump(peer);
    return peer;
}

fn peer_kill(sd: *SharedData, ref_id: usize) !void {
    const peer = sd.peer_pool.items[ref_id];
    const endp = ptc.Protocol.init(
        ptc.Typ.RES,
        ptc.Act.COMM_END,
        ptc.StatusCode.OK,
        "server",
        "server",
        "client",
        "OK",
    );
    endp.dump(LOG_LEVEL);
    _ = ptc.prot_transmit(peer.stream(), endp);
    sd.peer_remove(ref_id);
}

fn server_start(address: []const u8, port: u16) !net.Server {
    const lh = try net.Address.resolveIp(address, port);
    print("Server running on `{s}:{d}`\n", .{ address, port });
    return lh.listen(.{
        // TODO this flag needs to be set for bettter server performance
        .reuse_address = true,
    });
}

fn message_broadcast(
    sd: *SharedData,
    sender_id: []const u8,
    msg: []const u8,
) !void {
    var pind: usize = 0;
    const peer_ref = peer_find_id(sd.peer_pool, sender_id);
    if (peer_ref) |pf| {
        for (sd.peer_pool.items[0..]) |peer| {
            if (pf.ref_id != pind and peer.alive) {
                const src_addr = cmn.address_as_str(pf.peer.comm_address());
                const dst_addr = cmn.address_as_str(peer.comm_address());
                const msgp = ptc.Protocol.init(
                    ptc.Typ.RES,
                    ptc.Act.MSG,
                    ptc.StatusCode.OK,
                    sender_id,
                    src_addr,
                    dst_addr,
                    msg,
                );
                msgp.dump(LOG_LEVEL);
                _ = ptc.prot_transmit(peer.stream(), msgp);
            }
            pind += 1;
        }
    }
}

fn read_incomming(
    sd: *SharedData,
    conn: net.Server.Connection,
) !void {
    const stream = conn.stream;

    var buf: [256]u8 = undefined;
    _ = try stream.read(&buf);
    const recv = mem.sliceTo(&buf, 170);

    // Handle communication request
    var protocol = ptc.protocol_from_str(recv); // parse protocol from recieved bytes
    protocol.dump(LOG_LEVEL);

    const addr_str = cmn.address_as_str(conn.address);
    if (protocol.is_request()) {
        if (protocol.is_action(ptc.Act.COMM)) {
            const peer = peer_construct(conn, protocol);
            const peer_str = std.fmt.allocPrint(str_allocator, "{s}|{s}", .{ peer.id, peer.username }) catch "format failed";
            try sd.peer_add(peer);
            const resp = ptc.Protocol.init(
                ptc.Typ.RES,
                ptc.Act.COMM,
                ptc.StatusCode.OK,
                "server",
                "server",
                addr_str,
                peer_str,
            );
            resp.dump(LOG_LEVEL);
            _ = ptc.prot_transmit(stream, resp);
        } else if (protocol.is_action(ptc.Act.COMM_END)) {
            const peer_ref = peer_find_id(sd.peer_pool, protocol.sender_id);
            if (peer_ref) |pf| {
                try peer_kill(sd, pf.ref_id);
            }
        } else if (protocol.is_action(ptc.Act.MSG)) {
            try message_broadcast(sd, protocol.sender_id, protocol.body);
        } else if (protocol.is_action(ptc.Act.GET_PEER)) {
            // TODO: make a peer_find_bridge_ref
            //      - similar to peer_find_id
            //      - constructs a structure of sender peer and search peer
            const sref = peer_find_id(sd.peer_pool, protocol.sender_id);
            const ref = peer_find_id(sd.peer_pool, protocol.body);
            if (sref) |sr| {
                if (ref) |pr| {
                    const dst_addr = cmn.address_as_str(sr.peer.comm_address());
                    const resp = ptc.Protocol.init(
                        ptc.Typ.RES, // type
                        ptc.Act.GET_PEER, // action
                        ptc.StatusCode.OK, // status code
                        "server", // sender id
                        "server", // src
                        dst_addr, // dst
                        pr.peer.username, // body
                    );
                    resp.dump(LOG_LEVEL);
                    _ = ptc.prot_transmit(sr.peer.stream(), resp);
                }
            }
        } else if (protocol.is_action(ptc.Act.NONE)) {
            const errp = ptc.Protocol.init(
                ptc.Typ.ERR,
                protocol.action,
                ptc.StatusCode.BAD_REQUEST,
                "server",
                "server",
                addr_str,
                @tagName(ptc.StatusCode.BAD_REQUEST),
            );
            errp.dump(LOG_LEVEL);
            _ = ptc.prot_transmit(stream, errp);
        }
    } else if (protocol.is_response()) {
        if (protocol.is_action(ptc.Act.COMM)) {
            const ref = peer_find_id(sd.peer_pool, protocol.sender_id);
            if (ref) |pr| {
                print("peer `{s}` is alive\n", .{pr.peer.username});
            } else {
                print("Peer with id `{s}` does not exist!\n", .{protocol.sender_id});
            }
        } 
    } else if (protocol.type == ptc.Typ.NONE) {
        const errp = ptc.Protocol.init(
            ptc.Typ.ERR,
            protocol.action,
            ptc.StatusCode.BAD_REQUEST,
            "server",
            "server",
            addr_str,
            "bad request",
        );
        errp.dump(LOG_LEVEL);
        _ = ptc.prot_transmit(stream, errp);
    } else {
        std.log.err("unreachable code", .{});
    }
}

fn server_core(
    sd: *SharedData,
    server: *net.Server,
) !void {
    while (true) {
        const conn = try server.accept();
        try read_incomming(sd, conn);
    }
    print("Thread `server_core` finished\n", .{});
}

fn print_usage() void {
    print("COMMANDS:\n", .{});
    print("    * :cc ................ clear screen\n", .{});
    print("    * :list .............. list all active peers\n", .{});
    print("    * :kill all .......... kill all peers\n", .{});
    print("    * :kill <peer_id> .... kill one peer\n", .{});
}

fn extract_command_val(cs: []const u8, cmd: []const u8) []const u8 {
    var splits = mem.split(u8, cs, cmd);
    _ = splits.next().?; // the `:msg` part
    const val = mem.trimLeft(u8, splits.next().?, " \n");
    if (val.len <= 0) {
        std.log.err("missing action value", .{});
        print_usage();
    }
    return val;
}

const SharedData = struct {
    m: std.Thread.Mutex,
    should_exit: bool,
    peer_pool: *std.ArrayList(Peer),

    pub fn update_value(self: *@This(), should: bool) void {
        self.m.lock();
        defer self.m.unlock();

        self.should_exit = should;
    }

    pub fn peer_kill_all(self: *@This()) void {
        self.m.lock();
        defer self.m.unlock();

        self.peer_pool.clearAndFree();
    }

    pub fn peer_remove(self: *@This(), pid: usize) void {
        self.m.lock();
        defer self.m.unlock();

        self.peer_pool.items[pid].alive = false;
        _ = self.peer_pool.orderedRemove(pid);
    }

    pub fn peer_ping_all(self: *@This(), address_str: []const u8) void {
        self.m.lock();
        defer self.m.unlock();
        var pid: usize = 0;
        for (self.peer_pool.items[0..]) |peer| {
            const reqp = ptc.Protocol{
                .type = ptc.Typ.REQ, // type
                .action = ptc.Act.COMM, // action
                .status_code = ptc.StatusCode.OK, // status_code
                .sender_id = "server", // sender_id
                .src = address_str, // src_address
                .dst = cmn.address_as_str(peer.comm_address()), // dst_addres
                .body = "check?", // body
            };
            reqp.dump(LOG_LEVEL);
            // TODO: I don't know why but i must send 2 requests to determine the status of the stream
            _ = ptc.prot_transmit(peer.stream(), reqp);
            const status = ptc.prot_transmit(peer.stream(), reqp);
            if (status == 1) {
                self.peer_pool.items[pid].alive = false;
            } 
            pid += 1;
        }
    }

    pub fn peer_clean(self: *@This()) void {
        self.m.lock();
        defer self.m.unlock();
        var pplen: usize = self.peer_pool.items.len;
        while (pplen > 0) {
            pplen -= 1;
            const p = self.peer_pool.items[pplen];
            peer_dump(p);
            if (p.alive == false) {
                _ = self.peer_pool.orderedRemove(pplen);
            }
        }
    }

    pub fn peer_add(self: *@This(), peer: Peer) !void {
        self.m.lock();
        defer self.m.unlock();

        try self.peer_pool.append(peer);
    }
};
fn read_cmd(
    sd: *SharedData,
    addr_str: []const u8,
    port: u16,
    start_time: std.time.Instant,
) !void {
    const address_str = std.fmt.allocPrint(str_allocator, "{s}:{d}", .{ addr_str, port }) catch "format failed";
    while (true) {
        // read for command
        var buf: [256]u8 = undefined;
        const stdin = std.io.getStdIn().reader();
        if (try stdin.readUntilDelimiterOrEof(buf[0..], '\n')) |user_input| {
            // Handle different commands
            if (mem.startsWith(u8, user_input, ":exit")) {
                std.log.warn(":exit not implemented", .{});
            } else if (mem.eql(u8, user_input, ":list")) {
                if (sd.peer_pool.items.len == 0) {
                    print("Peer list: []\n", .{});
                } else {
                    print("Peer list ({d}):\n", .{sd.peer_pool.items.len});
                    for (sd.peer_pool.items[0..]) |peer| {
                        peer_dump(peer);
                    }
                }
            } else if (mem.startsWith(u8, user_input, ":kill")) {
                const karrg = extract_command_val(user_input, ":kill");
                if (mem.eql(u8, karrg, "all")) {
                    for (sd.peer_pool.items[0..]) |peer| {
                        const endp = ptc.Protocol.init(
                            ptc.Typ.RES,
                            ptc.Act.COMM_END,
                            ptc.StatusCode.OK,
                            "server",
                            "server",
                            "client",
                            "OK",
                        );
                        endp.dump(LOG_LEVEL);
                        _ = ptc.prot_transmit(peer.stream(), endp);
                    }
                    sd.peer_kill_all();
                } else {
                    const peer_ref = peer_find_id(sd.peer_pool, karrg);
                    if (peer_ref) |pf| {
                        try peer_kill(sd, pf.ref_id, );
                    }
                }
            } else if (mem.startsWith(u8, user_input, ":ping")) {
                const peer_un = extract_command_val(user_input, ":ping");
                if (mem.eql(u8, peer_un, "all")) {
                    sd.peer_ping_all(address_str);
                } else {
                    const ref = peer_find_username(sd.peer_pool, peer_un);
                    if (ref) |pr| {
                        const reqp = ptc.Protocol{
                            .type = ptc.Typ.REQ, // type
                            .action = ptc.Act.COMM, // action
                            .status_code = ptc.StatusCode.OK, // status_code
                            .sender_id = "server", // sender_id
                            .src = address_str, // src_address
                            .dst = cmn.address_as_str(pr.peer.comm_address()), // dst_addres
                            .body = "check?", // body
                        };
                        reqp.dump(LOG_LEVEL);
                        // TODO: I don't know why but i must send 2 requests to determine the status of the stream
                        _ = ptc.prot_transmit(pr.peer.stream(), reqp);
                        const status = ptc.prot_transmit(pr.peer.stream(), reqp);
                        if (status == 1) {
                            print("peer `{s}` is dead\n", .{pr.peer.username});
                            sd.peer_remove(pr.ref_id);
                        }  
                    } else {
                        std.log.warn("Peer with username `{s}` does not exist!\n", .{peer_un});
                    }
                }
            } else if (mem.eql(u8, user_input, ":clean")) {
                sd.peer_clean();
            } else if (mem.eql(u8, user_input, ":cc")) {
                try cmn.screen_clear();
                print("Server running on `{s}`\n", .{"127.0.0.1:6969"});
            } else if (mem.eql(u8, user_input, ":info")) {
                const now = try std.time.Instant.now();
                const dt = now.since(start_time) / std.time.ns_per_ms / 1000;
                print("==================================================\n", .{});
                print("Server status\n", .{});
                print("--------------------------------------------------\n", .{});
                print("peers connected: {d}\n", .{sd.peer_pool.items.len});
                print("uptime: {d:.3}s\n", .{dt});
                print("address: {s}\n", .{ address_str });
                print("==================================================\n", .{});
            } else if (mem.eql(u8, user_input, ":help")) {
                print_usage();
            } else {
                print("Unknown command: `{s}`\n", .{user_input});
                print_usage();
            }
        } else {
            print("Unreachable, maybe?\n", .{});
        }
    }
    print("Thread `run_cmd` finished\n", .{});
}

fn polizei(sd: *SharedData) !void {
    //std.log.err("not implemented", .{});
    //std.posix.exit(1);
    var start_t = try std.time.Instant.now();
    while (true) {
        const now_t = try std.time.Instant.now();
        const dt  = now_t.since(start_t) / std.time.ns_per_s;
        if (dt > 5 and dt < 7) {
            sd.peer_ping_all("server");
            sd.peer_clean();
            start_t = try std.time.Instant.now();
        }
    }
}

pub fn start() !void {
    try cmn.screen_clear();

    var server = try server_start(SERVER_ADDRESS, SERVER_PORT);
    errdefer server.deinit();
    defer server.deinit();
    const start_time = try std.time.Instant.now();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();

    //var messages = std.ArrayList(u8).init(gpa_allocator);
    //defer messages.deinit();

    var peer_pool = std.ArrayList(Peer).init(gpa_allocator);
    defer peer_pool.deinit();
    var sd = SharedData{
        .m = std.Thread.Mutex{},
        .should_exit = false,
        .peer_pool = &peer_pool,
    };
    {
        const t1 = try std.Thread.spawn(.{}, server_core, .{ &sd, &server });
        defer t1.join();
        const t2 = try std.Thread.spawn(.{}, read_cmd, .{ &sd, SERVER_ADDRESS, SERVER_PORT, start_time });
        defer t2.join();
        const t3 = try std.Thread.spawn(.{}, polizei, .{ &sd });
        defer t3.join();
    }
}
