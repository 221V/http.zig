
// ws example (wss - with cert, with https) // todo - this not works yet - f*ck build.zig ..

const std = @import("std");
const print = std.debug.print;

const httpz = @import("httpz");
const websocket = httpz.websocket;

const bearssl = @import("bearssl");
const Sha1 = std.crypto.hash.Sha1;
const base64 = std.base64.standard.Encoder;

const fibers = @import("fibers2.zig");


const PORT = 443;
const HOST = "0.0.0.0";

const FULLCHAIN_CERT = "examples_ws/cert/fullchain.pem";
const PRIVKEY_CERT = "examples_ws/cert/privkey.pem";


const INDEX_HTML =
\\<!DOCTYPE html>
\\<html>
\\<head>
\\<meta charset="UTF-8">
\\<title>WSS Game Server</title>
\\</head>
\\<body>
\\<h1>Websocket example 2 - wss - https<br>HTTPS + WSS Fiber Server</h1>
\\<div id="status">Connecting...</div>
\\<div id="log" style="background:#000;padding:1em;height:300px;overflow-y:auto;border:1px solid #333;"></div>
\\<script>
\\const log = (m) => { const d=document.createElement('div'); d.textContent=m; document.getElementById('log').appendChild(d); };
\\const ws = new WebSocket("wss://" window.location.host + "/ws"); // wss - https at localhost with generated wildcard certificate
\\ws.onmessage = (e) => console.log("wss <- ", e.data); // from server
\\ws.onopen = () => { document.getElementById('status').textContent = 'WSS Connected'; ws.send("Hello from browser!"); };
\\ws.onclose = (e) => { document.getElementById('status').textContent = 'WSS Disconnected'; console.log('WSS Disconnected', e); };
\\</script>
\\</body>
\\</html>
;


const PlayerTask = struct {
    fd: std.posix.socket_t,
    ssl: *bearssl.Session,
    ws_reader: websocket.proto.Reader,
    player_id: u64,
    //handshake_done: bool = false,
    state: enum { HttpHeader, WebSocket, Closing } = .HttpHeader, // fiber state
    allocator: std.mem.Allocator,

    pub fn tick(self: *PlayerTask) anyerror!fibers.FiberAction {
      if (self.state == .Closing) return .close_fiber;
      
      var buf: [4096]u8 = undefined;
      const n = std.posix.read(self.fd, &buf) catch |err| {
        if (err == error.WouldBlock) return .continue_loop;
        return .close_fiber;
      };
      if (n == 0) return .close_fiber;
      
      try self.ssl.push_encrypted(buf[0..n]); // use BearSSL
      
      var plain_buf: [4096]u8 = undefined;
      while (try self.ssl.pull_decrypted(&plain_buf)) |plain| {
        switch (self.state) {
          .HttpHeader => { // ckeck is this ws upgrade -- else main page
            if (std.mem.indexOf(u8, plain, "Upgrade: websocket") != null) {
              try self.handle_wss_handshake(plain);
              self.state = .WebSocket;
              try self.on_ws_init();
            
            }else if (std.mem.indexOf(u8, plain, "GET / ") != null) {
              try self.handle_http_serve();
              self.state = .Closing;
              return .continue_loop;
            }
          },
          
          .WebSocket => { // process WebSocket frames via httpz.proto, Reader.read() returns {more, message}
            while (try self.ws_reader.read()) |result| {
              const msg = result.@"1";
              try self.on_message(msg.data);
              self.ws_reader.done(msg.type);
            }
          },
          
          
          .Closing => return .close_fiber,
        }
      } // end while (try ..
      return .continue_loop;
    }
    
    
    fn handle_http_serve(self: *PlayerTask) !void { // handle html page via https
      const response = 
       "HTTP/1.1 200 OK\r\n" ++
       "Content-Type: text/html; charset=UTF-8\r\n" ++
       "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{INDEX_HTML.len}) ++ "\r\n" ++
       "Connection: close\r\n\r\n" ++
       INDEX_HTML;
      try self.ssl.write_all(response);
    }
    
    
    fn handle_wss_handshake(self: *PlayerTask, request: []const u8) !void {
      const key_header = "Sec-WebSocket-Key: ";
      const start = std.mem.indexOf(u8, request, key_header).? + key_header.len;
      const end = std.mem.indexOfScalarPos(u8, request, start, '\r').?;
      const key = request[start..end];
      
      var hasher = Sha1.init(.{}); // lets compute Sec-Websocket-Accept (SHA1 + Base64)
      hasher.update(key);
      hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
      var hash: [Sha1.digest_length]u8 = undefined;
      hasher.final(&hash);
      var accept_buf: [28]u8 = undefined;
      _ = base64.encode(&accept_buf, &hash);
      
      var response_buf: [256]u8 = undefined;
      const response = try std.fmt.bufPrint(&response_buf, 
       "HTTP/1.1 101 Switching Protocols\r\n" ++
       "Upgrade: websocket\r\n" ++
       "Connection: Upgrade\r\n" ++
       "Sec-Websocket-Accept: {s}\r\n\r\n", .{accept_buf});
      
      try self.ssl.write_all(response);
    }
    
    
    pub fn deinit(self: *PlayerTask) void {
      if (self.state == .WebSocket) {
        print("DB: Player {d} disconnected. Saving progress...", .{self.player_id});
        // db.save(self.player_id);
      }
      std.posix.close(self.fd);
      // self.ws_reader.deinit(); // clean httpz Reader
      self.allocator.free(self.ws_reader.static);
      // self.ssl.deinit();
    }

    fn on_ws_init(self: *PlayerTask) !void {
      self.player_id = std.crypto.random.int(u32);
      std.log.info("Player {d} connected (WSS Fiber)", .{self.player_id});
      const framed = try websocket.frameText("Connected to Game Server\n");
      try self.ssl.write_all(&framed);
      try self.ssl.write_all(websocket.frameText("Welcome!"));
    }

    fn on_message(self: *PlayerTask, data: []const u8) !void {
      std.log.info("MSG from {d}: {s}", .{self.player_id, data});
      const reply = try websocket.frameText(data);
      try self.ssl.write_all(&reply);
    }
};


fn tickAllFibers(manager: anytype) !void {
  manager.poll_list.clearRetainingCapacity();
  for (manager.fibers.items) |f| {
    const fd = f.vtable.get_fd(f);
    if (fd != -1) try manager.poll_list.append(.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 });
  }
  
  if (manager.poll_list.items.len > 0) {
    _ = std.posix.poll(manager.poll_list.items, 1) catch 0;
  }
  
  var i: usize = 0;
  while (i < manager.fibers.items.len) {
    const fiber = manager.fibers.items[i];
    const fd = fiber.vtable.get_fd(fiber);
    
    var ready = (fd == -1);
    if (!ready) {
      for (manager.poll_list.items) |pfd| {
        if (pfd.fd == fd) { ready = (pfd.revents != 0); break; }
      }
    }
    
    if (ready) {
      const action = fiber.vtable.tick(fiber) catch .close_fiber;
      if (action == .close_fiber) {
        fiber.vtable.deinit(fiber);
        _ = manager.fibers.swapRemove(i);
        continue;
      }
    }
    
    i += 1;
  }
}


pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();
  
  const cert_file = try std.fs.cwd().readFileAlloc(allocator, FULLCHAIN_CERT, 1024 * 10);
  defer allocator.free(cert_file);
  const key_file = try std.fs.cwd().readFileAlloc(allocator, PRIVKEY_CERT, 1024 * 10);
  defer allocator.free(key_file);
  try bearssl.ServerContext.init(allocator, cert_file, key_file);
  
  var buffer_provider = try websocket.bufferProvider(std.testing.io, allocator, .{ .max = 65536 });
  
  const address = try std.net.Address.parseIp("0.0.0.0", PORT);
  const server_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0);
  try std.posix.setsockopt(server_fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
  try std.posix.bind(server_fd, &address.any, address.getOsSockLen());
  try std.posix.listen(server_fd, 511);
  
  var manager = fibers.FiberManager(PlayerTask).init(allocator);
  defer manager.deinit();
  
  print("Pure Zig HTTPS/WSS Game Server online at https://{s}:{d}/\n", .{ HOST, PORT });
  
  while (true) { // waiting for new connections
    var pfds = [_]std.posix.pollfd{.{ .fd = server_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    if ((std.posix.poll(&pfds, 0) catch 0) > 0) {
      if (std.posix.accept(server_fd, null, null, std.posix.SOCK.NONBLOCK)) |client_fd| {
        const ws_buf = try allocator.alloc(u8, 4096); // reader buffer
        manager.spawn(.{ // new task as fiber
          .fd = client_fd,
          .player_id = std.crypto.random.int(u64),
          .ssl = try bearssl.createSession(client_fd),
          .ws_reader = websocket.proto.Reader.init(ws_buf, &buffer_provider, null), // init httpz buffers
          .allocator = allocator,
        }) catch |err| {
          std.log.err("Spawn error: {}", .{err});
          std.posix.close(client_fd);
          allocator.free(ws_buf);
        };
      } else |_| {}
    }
    
    try tickAllFibers(&manager);// run all active players // this must one tick per every player
    std.Thread.yield();
  }
}

