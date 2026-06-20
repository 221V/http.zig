
// ws example (without cert - without https-wss)
// This example show how to upgrade a request to websocket

const std = @import("std");
const print = std.debug.print;

const httpz = @import("httpz");
const websocket = httpz.websocket;

const Allocator = std.mem.Allocator;

const PORT = 8808;


// websocket.zig is verbose, let's limit it to err messages
pub const std_options = std.Options{ .log_scope_levels = &[_]std.log.ScopeLevel{
    .{ .scope = .websocket, .level = .err },
} };


const WS_Handler = Handler.WebsocketHandler;


const Handler = struct {
  pub const WebsocketHandler = struct {
    //user_id: u32,
    conn: *websocket.Conn,

    const Context = struct {
        user_id: u32,
    };

    //pub fn init(conn: *websocket.Conn, ctx: *const Context) !WebsocketHandler { // context is any abitrary data that you want, you'll pass it to upgradeWebsocket
    pub fn init(conn: *websocket.Conn, _: void) !WebsocketHandler { // context is any abitrary data that you want, you'll pass it to upgradeWebsocket
        return .{
            .conn = conn,
            //.user_id = ctx.user_id,
        };
    }

    //pub fn afterInit(self: *Handler.WebsocketHandler) !void { // at this point, it's safe to write to conn
    pub fn afterInit(self: *WS_Handler) !void { // at this point, it's safe to write to conn
        return self.conn.write("Hello from httpz WebSocket Server! :)");
    }

    //pub fn clientMessage(self: *Handler.WebsocketHandler, data: []const u8) !void {
    pub fn clientMessage(self: *WS_Handler, data: []const u8) !void {
        print("got data -> {s}\n", .{ data });
        //try self.conn.write("Еchо: "); // this works
        return self.conn.write(data); // echo back to client
    }
  };
};


fn index(_: Handler, _: *httpz.Request, res: *httpz.Response) !void {
  res.content_type = .HTML;
  res.body =
    \\<!DOCTYPE html>
    \\<html>
    \\<body>
    \\<h1>Websocket example 1</h1>
    \\<h3>please check browser console</h3>
    \\<p>httpz integrates with my own <a href="https://github.com/karlseguin/websocket.zig/">websocket.zig</a>.
    \\<p>A websocket connection should already be established.</p>
    \\<p>Copy and paste the following in your browser console to have the server echo back one more time:</p>
    \\<pre>ws.send("hello from the client!");</pre>
    \\<script>
    \\const ws = new WebSocket("ws://localhost:8808/ws"); // same PORT
    \\ws.onmessage = (e) => console.log("ws <- ", e.data); // from server
    \\ws.onopen = () => { console.log("WS Connected!"); ws.send("Hello from browser!"); };
    \\ws.onclose = (e) => console.log("WS Disconnected!", e);
    \\</script>
    \\</body>
    \\</html>
  ;
}


fn ws_upgrade(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Could do authentication or anything else before upgrading the connection
    // The context is any arbitrary data you want to pass to Client.init.
    //const ctx = WS_Handler.Context{ .user_id = 9001 };

    //if (try httpz.upgradeWebsocket(WS_Handler, req, res, &ctx) == false) {
    if (try httpz.upgradeWebsocket(WS_Handler, req, res, {}) == false) {
        res.status = 500;
        res.body = "invalid websocket upgrade";
    }
    // unsafe to use req or res at this point!
}


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // For websocket support, you _must_ define a Handler, and
    //  your Handler _must_ have a WebsocketHandler declaration
    var server = try httpz.Server(Handler).init(allocator, .{.port = PORT}, Handler{});
    defer server.deinit();
    defer server.stop(); // ensures a clean shutdown, finishing off any existing requests; see 09_shutdown.zig for how to break server.listen with an interrupt

    var router = try server.router(.{});
    router.get("/", index, .{});
    router.get("/ws", ws_upgrade, .{});

    print("listening http://localhost:{d}/\n", .{PORT});
    try server.listen(); // Starts the server, this is blocking
}

