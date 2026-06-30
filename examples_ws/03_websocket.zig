
// ws with Pub/Sub example

const std = @import("std");
const print = std.debug.print;

const httpz = @import("httpz");
const websocket = httpz.websocket;

const Allocator = std.mem.Allocator;


const PORT = 8808;


const ChatManager = struct { // simple Pub/Sub for httpz - rooms chat examples // todo add html forms for join and leave room
  mutex: std.Thread.RwLock = .{},
  rooms: std.StringHashMap(std.ArrayList(*websocket.Conn)), // rooms with active clients
  allocator: std.mem.Allocator,

  pub fn init(allocator: std.mem.Allocator) ChatManager {
    return .{
      .rooms = std.StringHashMap(std.ArrayList(*websocket.Conn)).init(allocator),
      .allocator = allocator,
    };
  }

  pub fn subscribe(self: *ChatManager, room_name: []const u8, conn: *websocket.Conn) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    
    var res = try self.rooms.getOrPut(room_name);
    if (!res.found_existing) {
      res.key_ptr.* = try self.allocator.dupe(u8, room_name);
      res.value_ptr.* = std.ArrayList(*websocket.Conn).init(self.allocator);
    }
    for (res.value_ptr.items) |existing_conn| {
      if (existing_conn == conn) return; // do not subscribe again when already done
    }
    try res.value_ptr.append(conn);
  }

  pub fn unsubscribe_all(self: *ChatManager, conn: *websocket.Conn) void { // todo unsubscribe single room
    self.mutex.lock();
    defer self.mutex.unlock();
    
    var it = self.rooms.iterator();
    while (it.next()) |entry| {
      var list = entry.value_ptr;
      for (list.items, 0..) |c, i| {
        if (c == conn) {
          _ = list.swapRemove(i);
          break;
        }
      }
    }
  }

  pub fn publish(self: *ChatManager, room_name: []const u8, msg: []const u8, sender: *websocket.Conn) void {
    self.mutex.lockShared();
    defer self.mutex.unlockShared();
    
    if (self.rooms.get(room_name)) |clients| {
      for (clients.items) |client| {
        if (client != sender) {
          client.write(msg) catch {};
        }
      }
    }
  }
  
  pub fn deinit(self: *ChatManager) void {
    var it = self.rooms.iterator();
    while (it.next()) |entry| {
      self.allocator.free(entry.key_ptr.*);
      entry.value_ptr.deinit();
    }
    self.rooms.deinit();
  }
};


var global_chat: ChatManager = undefined;

const WS_Handler = Handler.WebsocketHandler;


const Handler = struct {
  pub const WebsocketHandler = struct {
    //user_id: u32,
    conn: *websocket.Conn,

    //const Context = struct {
    //    user_id: u32,
    //};

    //pub fn init(conn: *websocket.Conn, ctx: *const Context) !WebsocketHandler { // context is any abitrary data that you want, you'll pass it to upgradeWebsocket
    pub fn init(conn: *websocket.Conn, _: void) !WebsocketHandler { // context is any abitrary data that you want, you'll pass it to upgradeWebsocket
      try global_chat.subscribe("general", conn); // join "general" room by default
      return .{
        .conn = conn,
        //.user_id = ctx.user_id,
      };
    }

    //pub fn afterInit(self: *Handler.WebsocketHandler) !void { // at this point, it's safe to write to conn
    pub fn afterInit(self: *WS_Handler) !void { // at this point, it's safe to write to conn
      return self.conn.write("Joined 'general'. Send 'room:message' to chat or 'join:room' to subscribe.");
    }

    pub fn clientMessage(self: *WS_Handler, allocator: std.mem.Allocator, data: []const u8) !void {
      if (std.mem.indexOfScalar(u8, data, ':')) |idx| {
        const cmd_or_room = data[0..idx];
        const content = data[idx + 1 ..];

        if (std.mem.eql(u8, cmd_or_room, "join")) { // 'join:room'
          try global_chat.subscribe(content, self.conn);
          const msg_success = try std.fmt.allocPrint(allocator, "Subscribed to room: {s}", .{ content });
          try self.conn.write(msg_success);
        
        } else { // 'room:message'
          global_chat.publish(cmd_or_room, data, self.conn);
        }
      
      } else {
        try self.conn.write("Error: use 'room:message' format");
      }
    }

    pub fn clientClose(self: *WS_Handler, _: []const u8) !void {
      global_chat.unsubscribe_all(self.conn);
    }
  };
};


fn ws_upgrade(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
  //const ctx = WS_Handler.Context{ .user_id = 9001 };
  
  //if (try httpz.upgradeWebsocket(WS_Handler, req, res, &ctx) == false) {
  if (try httpz.upgradeWebsocket(WS_Handler, req, res, {}) == false) {
    res.status = 500;
    res.body = "invalid websocket upgrade";
  }
  // unsafe to use req or res at this point!
}


fn index(_: Handler, _: *httpz.Request, res: *httpz.Response) !void {
  res.content_type = .HTML;
  res.body =
\\<!DOCTYPE html>
\\<html>
\\<head>
\\<meta charset="UTF-8">
\\<title>ws + PubSub</title>
\\</head>
\\<body>
\\<h1>Websocket example 3 - ws + PubSub</h1>
\\<div id="status">Connecting...</div>
\\<h3>please check browser console</h3>
\\<!--<div id="log" style="background:#000;padding:1em;height:300px;overflow-y:auto;border:1px solid #333;"></div>-->
\\<script>
\\const log = (m) => { const d = document.createElement('div'); d.textContent = m; document.getElementById('log').appendChild(d); };
\\const proto = location.protocol === "https:" ? "wss" : "ws";
\\const ws = new WebSocket(proto + "://" + window.location.host + "/ws");
\\ws.onmessage = (e) => console.log("ws <- ", e.data); // from server
\\ws.onopen = () => { document.getElementById('status').textContent = 'WS Connected'; ws.send("general:Hello from browser!"); };
\\ws.onclose = (e) => { document.getElementById('status').textContent = 'WS Disconnected'; console.log('WS Disconnected', e); };
\\</script>
\\</body>
\\</html>
  ;
}



pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();
  
  global_chat = ChatManager.init(allocator);
  defer global_chat.rooms.deinit();
  
  var server = try httpz.Server(Handler).init(allocator, .{.port = PORT}, Handler{});
  defer server.deinit();
  defer server.stop();
  
  var router = try server.router(.{});
  router.get("/", index, .{});
  router.get("/ws", ws_upgrade, .{});
  
  print("listening http://localhost:{d}/\n", .{ PORT });
  try server.listen(); // this is blocking
}

