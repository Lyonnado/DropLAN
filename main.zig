const std = @import("std");

const ws2 = @cImport({
    @cInclude("winsock2.h");
    @cInclude("ws2tcpip.h");
});

const iphlp = @cImport({
    @cInclude("iphlpapi.h");
});

const win = @cImport({
    @cInclude("windows.h");
});


var ip_buffer: [64]u8 = undefined;


fn get_local_ip() []const u8 {
    var size: u32 = 0;

    _ = iphlp.GetAdaptersInfo(null, &size);

    if (size == 0)
        return "127.0.0.1";


    const buffer = std.heap.page_allocator.alloc(u8, size)
        catch return "127.0.0.1";

    defer std.heap.page_allocator.free(buffer);


    const adapter =
        @as(*iphlp.IP_ADAPTER_INFO, @ptrCast(@alignCast(buffer.ptr)));


    if (iphlp.GetAdaptersInfo(adapter, &size) != 0)
        return "127.0.0.1";


    var current: ?*iphlp.IP_ADAPTER_INFO = adapter;


    while (current) |item| {

        const ip = std.mem.span(
            @as([*:0]const u8,
            @ptrCast(&item.IpAddressList.IpAddress))
        );


        if (std.mem.startsWith(u8, ip, "192.168.")) {

            @memcpy(ip_buffer[0..ip.len], ip);

            return ip_buffer[0..ip.len];
        }


        current = item.Next;
    }


    return "127.0.0.1";
}




fn send_all(sock: ws2.SOCKET, data: []const u8) bool {

    var offset: usize = 0;

    while (offset < data.len) {

        const n = ws2.send(
            sock,
            data.ptr + offset,
            @intCast(data.len - offset),
            0,
        );


        if (n == ws2.SOCKET_ERROR)
            return false;


        offset += @intCast(n);
    }


    return true;
}




fn send_header(
    client: ws2.SOCKET,
    size: usize,
    content_type: []const u8,
) bool {

    var header: [1024]u8 = undefined;


    const h = std.fmt.bufPrint(
        &header,

        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: {}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n",

        .{
            size,
            content_type,
        },

    ) catch return false;


    return send_all(client, h);
}




fn send_text(
    client: ws2.SOCKET,
    body: []const u8,
    content_type: []const u8,
) void {

    if (!send_header(
        client,
        body.len,
        content_type,
    ))
        return;


    _ = send_all(client, body);
}





fn send_file(
    client: ws2.SOCKET,
    path: []const u8,
) void {

    const file = std.fs.openFileAbsolute(
        path,
        .{},
    ) catch return;


    defer file.close();


    const stat = file.stat()
        catch return;


    if (!send_header(
        client,
        stat.size,
        "application/octet-stream",
    ))
        return;


    var buffer: [8192]u8 = undefined;


    while (true) {

        const n = file.read(&buffer)
            catch break;


        if (n == 0)
            break;


        if (!send_all(
            client,
            buffer[0..n],
        ))
            break;
    }
}




fn url_decode(
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]u8 {

    var out = std.ArrayList(u8){};


    var i: usize = 0;


    while (i < input.len) {

        if (input[i] == '%' and i + 2 < input.len) {

            try out.append(
                allocator,
                try std.fmt.parseInt(
                    u8,
                    input[i+1..i+3],
                    16,
                ),
            );

            i += 3;

        } else if (input[i] == '+') {

            try out.append(
                allocator,
                ' ',
            );

            i += 1;

        } else {

            try out.append(
                allocator,
                input[i],
            );

            i += 1;
        }
    }


    return out.toOwnedSlice(allocator);
}

fn make_index(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
) ![]u8 {

    var html = std.ArrayList(u8){};


    try html.appendSlice(
        allocator,
        "<html><head><meta charset=\"utf-8\">" ++
        "<title>QuickShare</title></head><body>" ++
        "<h2>QuickShare</h2><hr>",
    );


    var dir = try std.fs.openDirAbsolute(
        dir_path,
        .{ .iterate = true },
    );

    defer dir.close();


    var it = dir.iterate();


    while (try it.next()) |entry| {

        try html.writer(allocator).print(
            "<p><a href=\"/{s}\">{s}</a></p>",
            .{
                entry.name,
                entry.name,
            },
        );
    }


    try html.appendSlice(
        allocator,
        "</body></html>",
    );


    return html.toOwnedSlice(allocator);
}




fn handle_client(
    client: ws2.SOCKET,
    root: []const u8,
    allocator: std.mem.Allocator,
) void {

    var request: [4096]u8 = undefined;


    const len = ws2.recv(
        client,
        &request,
        request.len,
        0,
    );


    if (len <= 0)
        return;


    const req = request[0..@intCast(len)];


    var path: []const u8 = "/";


    if (std.mem.indexOf(u8, req, "GET ")) |p| {

        const start = p + 4;

        if (std.mem.indexOfScalarPos(
            u8,
            req,
            start,
            ' ',
        )) |end| {

            path = req[start..end];
        }
    }



    if (std.mem.eql(u8, path, "/")) {

        const html = make_index(
            allocator,
            root,
        ) catch return;


        defer allocator.free(html);


        send_text(
            client,
            html,
            "text/html; charset=utf-8",
        );

        return;
    }



    var clean = url_decode(
        allocator,
        path[1..],
    ) catch return;


    defer allocator.free(clean);



    if (std.mem.indexOfScalar(
        u8,
        clean,
        '?',
    )) |p| {

        clean = clean[0..p];
    }



    const full = std.fs.path.join(
        allocator,
        &.{
            root,
            clean,
        },
    ) catch return;


    defer allocator.free(full);


    send_file(
        client,
        full,
    );
}






pub fn main() !void {

    _ = win.SetConsoleOutputCP(65001);
    _ = win.SetConsoleCP(65001);

    var arena = std.heap.ArenaAllocator.init(
        std.heap.page_allocator,
    );

    defer arena.deinit();


    const allocator = arena.allocator();



    var args = try std.process.argsWithAllocator(
        allocator,
    );

    defer args.deinit();



    _ = args.next();



    const input = args.next() orelse {

        std.debug.print(
            "请拖文件或文件夹到 QuickShare.exe\n",
            .{},
        );

        return;
    };



    var root: []const u8 = undefined;



    const info = std.fs.cwd().statFile(
        input,
    ) catch null;



    if (info) |s| {

        root = if (s.kind == .directory)
            input
        else
            std.fs.path.dirname(input) orelse ".";

    } else {

        return;
    }






    var wsa: ws2.WSAData = undefined;


    if (ws2.WSAStartup(
        0x202,
        &wsa,
    ) != 0)
        return;


    defer _ = ws2.WSACleanup();





    const server = ws2.socket(
        ws2.AF_INET,
        ws2.SOCK_STREAM,
        ws2.IPPROTO_TCP,
    );


    if (server == ws2.INVALID_SOCKET)
        return;



    var addr = std.mem.zeroes(
        ws2.sockaddr_in,
    );


    addr.sin_family = ws2.AF_INET;

    addr.sin_port = ws2.htons(8000);

    addr.sin_addr = std.mem.zeroes(
        @TypeOf(addr.sin_addr),
    );



    if (ws2.bind(
        server,
        @ptrCast(&addr),
        @sizeOf(ws2.sockaddr_in),
    ) == ws2.SOCKET_ERROR)
        return;



    if (ws2.listen(server, 10)
        == ws2.SOCKET_ERROR)
        return;





    std.debug.print(
        "\n============================\n" ++
        "QuickShare\n\n" ++
        "共享目录:\n{s}\n\n" ++
        "手机访问:\nhttp://{s}:8000\n\n" ++
        "Ctrl+C 停止\n\n",

        .{
            root,
            get_local_ip(),
        },
    );





    while (true) {

        const client = ws2.accept(
            server,
            null,
            null,
        );


        if (client == ws2.INVALID_SOCKET)
            continue;



        handle_client(
            client,
            root,
            allocator,
        );


        _ = ws2.shutdown(
            client,
            ws2.SD_BOTH,
        );


        _ = ws2.closesocket(client);
    }
}