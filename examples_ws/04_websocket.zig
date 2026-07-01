
// upload files via ws example

const std = @import("std");
const print = std.debug.print;

const httpz = @import("httpz");
const websocket = httpz.websocket;

const Bert = @import("bert.zig").Bert; // https://github.com/221V/zig_erl_bert  for BERT encode-decode
const Bert_Value = @import("bert.zig").Bert_Value;


const PORT = 8808;


const ExtensionsLimits = struct {
  //ext: []const u8,
  exts: []const []const u8, // for set few filetypes with same max size
  size: usize,
};


const UploadConfig = struct {
  save_path_temp: []const u8 = "uploads/temp",
  save_path_root: []const u8 = "uploads",
  max_size_default: usize = 10 * 1024 * 1024, // default 10Mb
  
  allow_extensions: ?[]const []const u8 = &.{ ".jpg", ".png", ".gif", ".txt", ".pdf", ".mp3", ".mp4", ".avi" },
  deny_extensions: ?[]const []const u8 = &.{ ".exe", ".sh" },
  
  extension_limits: []const ExtensionsLimits = &.{
    .{ .exts = &.{ ".txt" }, .size = 1 * 1024 * 1024 }, // 1Mb max
    .{
       .exts = &.{ ".jpg", ".png", ".gif", ".pdf" },
       .size = 5 * 1024 * 1024 // 5Mb max
    },
    .{
       .exts = &.{ ".mp3", ".mp4" },
       .size = 50 * 1024 * 1024 // 50Mb max
    },
    .{ .exts = &.{ ".avi" }, .size = 2 * 1024 * 1024 * 1024 }, // 2Gb max
  },
  
  ttl_seconds: i64 = 24 * 60 * 60, // 24 hours for temp files
};

const config = UploadConfig{};


const UploadState = struct { // session state for uploads
  file: std.fs.File,
  path_temp: []const u8,
  path_done: []const u8,
  total_size: usize,
  current_size: usize,
  //last_update: i64,
};


// helpers

fn checkLimits(name: []const u8, size: usize) !void {
  const raw_ext = std.fs.path.extension(name);

  var ext_buf: [10]u8 = undefined; // 10 chars length for files extension
  if (raw_ext.len >= ext_buf.len) return error.ExtensionTooLong;

  const lower_ext = std.ascii.lowerString(&ext_buf, raw_ext);
  const ext = std.mem.trim(u8, lower_ext, &[_]u8{ 0, ' ', '\t', '\r', '\n' });

  std.log.info("CheckLimits: file='{s}', raw_ext='{s}', normalized_ext='{s}', size={d}", .{ name, raw_ext, ext, size });

  if (config.deny_extensions) |list| { // check blacklist
    for (list) |denied| {
      //if (std.mem.eql(u8, ext, denied)) return error.ExtensionDenied;
      if (std.ascii.eqlIgnoreCase(ext, denied)) return error.ExtensionDenied;
    }
  }

  if (config.allow_extensions) |list| { // check whitelist
    var found = false;
    for (list) |allowed| {
      //if (std.mem.eql(u8, ext, allowed)) { found = true; break; }
      if (std.ascii.eqlIgnoreCase(ext, allowed)) { found = true; break; }
    }
    if (!found){
      std.log.err("CheckLimits: Extension '{s}' not found in allow list", .{ext});
      return error.ExtensionNotAllowed;
    }
  }

  var limit = config.max_size_default;

  outer: for (config.extension_limits) |group| { // lets check file size limit // label :outer for exit both loops
    for (group.exts) |group_ext| {
      //if (std.mem.eql(u8, ext, group_ext)) {
      if (std.ascii.eqlIgnoreCase(ext, group_ext)) {
        limit = group.size;
        //std.log.info("CheckLimits: Matched group for '{s}', setting limit to {d}", .{group_ext, limit});
        break :outer; // limit found, stop search
      }
    }
  }

  //std.log.info("CheckLimits: Checking size {d} vs limit {d}", .{size, limit});
  if (size > limit) {
    std.log.err("CheckLimits: FAILED. Size {d} > Limit {d}", .{size, limit});
    return error.FileTooLarge;
  }
}


fn getSavePath(allocator: std.mem.Allocator, filename: []const u8, total_size: usize) ![]const u8 {
  //const ts = std.time.timestamp(); // construct path: root/timestamp_file
  //const basename = std.fs.path.basename(filename);
  //std.log.info("getSavePath: config.save_path_root = '{s}', basename = '{s}', ts = {d}", .{ config.save_path_root, basename, ts });

  var hasher = std.hash.Wyhash.init(0); // construct path: root/<HASH>.<EXT>
  hasher.update(filename);
  hasher.update(std.mem.asBytes(&total_size));
  const hash = hasher.final();

  const raw_ext = std.fs.path.extension(filename);

  var ext_buf: [10]u8 = undefined; // 10 chars length for files extension
  //if (raw_ext.len >= ext_buf.len) return error.ExtensionTooLong;

  const ext = if (raw_ext.len < ext_buf.len)
    std.ascii.lowerString(&ext_buf, raw_ext)
  else
    raw_ext;

  //std.log.info("getSavePath: config.save_path_root = '{s}', ext = '{s}', ts = {d}", .{ config.save_path_root, ext, ts });
  std.log.info("getSavePath: config.save_path_root = '{s}', hash = '{x}', ext = {s}", .{ config.save_path_root, hash, ext });
  return std.fmt.allocPrint(allocator, "{s}/{x}{s}", .{config.save_path_root, hash, ext}); // .{config.save_path_root, ts, ext}); // .{config.save_path_root, ts, basename});
}


//fn getFileInfo(allocator: std.mem.Allocator, filename: []const u8, total_size: usize, is_temp: bool) !struct{ path: []const u8, id: []const u8 } {
fn getFileInfo(allocator: std.mem.Allocator, filename: []const u8, total_size: usize) !struct{ path_temp: []const u8, path_done: []const u8, id: []const u8 } {
  var hasher = std.hash.Wyhash.init(0);
  hasher.update(filename);
  hasher.update(std.mem.asBytes(&total_size));
  const hash = hasher.final();

  const ext = std.fs.path.extension(filename);
  const id_str = try std.fmt.allocPrint(allocator, "{x}", .{hash}); // id = hex hash

  //const root = if (is_temp) config.save_path_temp else config.save_path_root;
  //const path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{root, id_str, ext});

  //return .{ .path = path, .id = id_str };
  return .{
    .id = id_str,
    .path_temp = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ config.save_path_temp, id_str, ext }),
    .path_done = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ config.save_path_root, id_str, ext }),
  };
}


fn cleanup_task() !void {
  std.log.info("Cleanup task started", .{});
  //const allocator = std.heap.page_allocator;
  while (true) {
    std.time.sleep(std.time.ns_per_hour); // sleep 1 hour
    std.log.info("Cleanup task: Scanning for stale uploads...", .{});
    var dir = std.fs.cwd().openDir(config.save_path_temp, .{ .iterate = true }) catch continue;
    defer dir.close();

    var iter = dir.iterate();
    const now = std.time.timestamp();

    while (iter.next() catch null) |entry| {
      if (entry.kind == .file) {
        const stat = dir.statFile(entry.name) catch continue;
        const mtime_sec = @divFloor(stat.mtime, std.time.ns_per_s); // time of last modification, in ns

        if (now - mtime_sec > config.ttl_seconds) {
          std.log.info("Cleanup task: Deleting stale file {s} (age: {d}s)", .{entry.name, now - mtime_sec});
          dir.deleteFile(entry.name) catch |e| std.log.err("Cleanup task delete error: {s}", .{ @errorName(e) });
        }
      }
    }
  }
}


const WS_Handler = Handler.WebsocketHandler;


const Handler = struct {
  allocator: std.mem.Allocator,
  
  pub const WebsocketHandler = struct {
    conn: *websocket.Conn,
    allocator: std.mem.Allocator,
    uploads: std.StringHashMap(UploadState), // open files in session

    pub fn init(conn: *websocket.Conn, allocator: std.mem.Allocator) !WebsocketHandler {
      return .{
        .conn = conn,
        .allocator = allocator,
        .uploads = std.StringHashMap(UploadState).init(allocator),
      };
    }

    pub fn clientMessage(self: *WebsocketHandler, allocator: std.mem.Allocator, data: []const u8) !void {
      var b = Bert.init(allocator);
      const val = b.decode(data) catch |e| { // for file data Bert_Value must be Tuple{ftp, id, ..., data, status}
        std.log.err("BERT Decode Error: {s}", .{ @errorName(e) });
        return;
      };

      if (val != .tuple or val.tuple.len != 13) return; // BERT {ftp, ID, Name, Total, Offset, Data, Status}  // not file data // n2o ftp protocol has 13 elements

      //switch (val) { 
      //  .tuple => |elems| {
      //    if(elems.len != 13){ return; } // not file data // n2o ftp protocol has 13 elements

          //const atom_tag = val.tuple[0]; // elems[0];
          //switch (atom_tag) {
          switch (val.tuple[0]) {
            .atom => |s| if (!std.mem.eql(u8, s, "ftp")) return, // check 'ftp' atom
            else => return,
          }

          const id = try get_binary_str(val.tuple[1]); // (elems[1]);
          const name = try get_binary_str(val.tuple[3]); // (elems[3]);
          const total = try get_int_usize(val.tuple[8]); // (elems[8]);
          const offset = try get_int_usize(val.tuple[9]); // (elems[9]);
          const bin_data = try get_binary_str(val.tuple[11]); // (elems[11]);
          const status = try get_binary_str(val.tuple[12]); // (elems[12]);

          var reply_status: []const u8 = "send";
          var current_offset: u64 = offset;
          var response_id: []const u8 = id;

          if (std.mem.eql(u8, status, "init")) { // start upload
            checkLimits(name, total) catch |err| {
              std.log.err("Limits check failed for {s}: {s}", .{ name, @errorName(err) });
              try self.sendReply(id, total, 0, "error", allocator);
              return;
            };

            std.fs.cwd().makePath(config.save_path_root) catch {};
            std.fs.cwd().makePath(config.save_path_temp) catch {};

            std.log.info("Init upload: {s} ({d} bytes)", .{name, total});

            const info = try getFileInfo(allocator, name, total);
            response_id = info.id;

            if (std.fs.cwd().access(info.path_done, .{})) |_| { // file already exists
              current_offset = total;
            } else |_| { // file not found
              //const file = std.fs.cwd().createFile(name, .{ .truncate = false, .read = true }) catch |e| {
              const file = std.fs.cwd().createFile(info.path_temp, .{ .truncate = false, .read = true }) catch |e| {
                std.log.err("Create File error: {s}", .{ @errorName(e) });
                try self.sendReply(id, total, 0, "error", allocator);
                return;
              };
              const stat = try file.stat();
              current_offset = @intCast(stat.size);
              try file.seekTo(current_offset);

              try self.uploads.put(try self.allocator.dupe(u8, info.id), .{
                .file = file,
                .path_temp = try self.allocator.dupe(u8, info.path_temp),
                .path_done = try self.allocator.dupe(u8, info.path_done),
                .total_size = total,
                .current_size = current_offset,
              });
            }


          } else if (std.mem.eql(u8, status, "send")) { // chunk received
            //if (self.uploads.get(id)) |file| { // here id must be server id because client has update it after init
            if (self.uploads.getPtr(id)) |state| { // here id must be server id because client has update it after init
              if (offset == state.current_size) {
                try state.file.writeAll(bin_data);
                state.current_size += bin_data.len; // @as(u64, @intCast(bin_data.len));
              }
              current_offset = state.current_size;

              if (state.current_size >= state.total_size) {
                state.file.close();
                
                //const now = std.time.timestamp();
                //const ext = std.fs.path.extension(state.path_done);
                //const stem = state.path_done[0 .. state.path_done.len - ext.len];
                //const final_path = try std.fmt.allocPrint(allocator, "{s}_{d}{s}", .{ stem, now, ext });
                
                std.fs.cwd().rename(state.path_temp, state.path_done) catch |e| { // todo check is file already exists before mv - do not rewrite same file with same name
                //std.fs.cwd().rename(state.path_temp, final_path) catch |e| { // use this case - with timestamp - when you do not care about files doubles
                  std.log.err("Move failed: {s}", .{ @errorName(e) });
                };
                _ = self.removeUpload(id);
              }

            }else{
              reply_status = "error";
            }
          }

          try self.sendReply(response_id, total, current_offset, reply_status, allocator);
        //}, // end .tuple
        //else => {},
      //}
    }

    fn sendReply(self: *WebsocketHandler, id: []const u8, total: usize, offset: usize, status: []const u8, allocator: std.mem.Allocator) !void {
      var b = Bert.init(allocator);
      var reply_tuple = [_]Bert_Value{ // encode Reply
        try b.atom("ftp"),
        try b.binary(id),
        try b.binary(""), // sid
        try b.binary(""), // name (empty for ack)
        try b.binary(""),
        try b.binary(""),
        try b.binary(""),
        try b.binary(""),
        b.int(@intCast(total)),
        b.int(@intCast(offset)),
        b.int(0), // block
        try b.binary(""), // data
        try b.binary(status),
      };

      std.log.info("WS: Sending Reply status='{s}' offset={d}", .{status, offset});
      const encoded = try b.encode(try b.tuple(&reply_tuple));
      try self.conn.writeBin(encoded);
    }

    fn removeUpload(self: *WebsocketHandler, id: []const u8) bool {
      if (self.uploads.fetchRemove(id)) |kv| {
        self.allocator.free(kv.key);
        self.allocator.free(kv.value.path_temp);
        self.allocator.free(kv.value.path_done);
        return true;
      }
      return false;
    }

    pub fn clientClose(self: *WebsocketHandler, _: []const u8) !void {
      var it = self.uploads.iterator();
      while (it.next()) |entry| {
        entry.value_ptr.file.close();
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.path_temp);
        self.allocator.free(entry.value_ptr.path_done);
      }
      self.uploads.deinit();
    }
  };
};


// helpers - BERT
fn get_binary_str(v: Bert_Value) ![]const u8 {
  return switch(v) { .binary => |b| b, else => error.NotBinary };
}

fn get_int_usize(v: Bert_Value) !usize {
  return switch(v) {
    //.int => |i| @intCast(i),
    //.big_int => 0,
    .int => |i| if (i < 0) error.NegativeValue else @intCast(i),
    .big_int => |bi| bi.toConst().toInt(usize) catch error.IntTooLarge,
    else => error.NotInt
  };
}


//fn ws_upgrade(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
fn ws_upgrade(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
  //const ctx = WS_Handler.Context{ .user_id = 9001 };
  
  //if (try httpz.upgradeWebsocket(WS_Handler, req, res, &ctx) == false) {
  //if (try httpz.upgradeWebsocket(WS_Handler, req, res, {}) == false) {
  //if (try httpz.upgradeWebsocket(WS_Handler, req, res, req.arena) == false) {
  if (try httpz.upgradeWebsocket(WS_Handler, req, res, handler.allocator) == false) {
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
\\<title>httpz + WS File Upload Example</title>
\\<style>body{font-family:sans-serif;padding:20px}</style>
\\</head>
\\<body>
\\<h2>httpz + WS File Upload Example</h2>
\\<input type="file" multiple onchange="selectFiles(this)">
\\<div id="ftp-status" style="margin-top:20px"></div>
\\<!-- <script src="/static/BigInteger.min.js" defer></script> -->
\\<script src="/static/bert_ftp.js" defer></script>
\\<script src="/static/form.js" defer></script>
\\</body>
\\</html>
  ;
}


fn serveStatic(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
  const path = req.url.path; // /static/form.js
  if (!std.mem.startsWith(u8, path, "/static/")) return;
  const file_relative = path["/static/".len..]; // cut /static/

  var path_buf: [256]u8 = undefined;
  const local_path = std.fmt.bufPrint(&path_buf, "examples_ws/static/{s}", .{ file_relative }) catch return; // path to local folder

  const file = std.fs.cwd().openFile(local_path, .{}) catch {
    res.status = 404;
    res.body = "File not found";
    return;
  };
  defer file.close();

  res.content_type = httpz.ContentType.forFile(local_path);
  
  var stream_buffer: [16384]u8 = undefined; // 16 kb
  
  while (true) {
    const bytes_read = try file.read(&stream_buffer); // chunked read - stream file
    if (bytes_read == 0) break;
    try res.chunk(stream_buffer[0..bytes_read]);
  }
}


pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer _ = gpa.deinit();
  const allocator = gpa.allocator();
  
  const thread = try std.Thread.spawn(.{}, cleanup_task, .{});
  thread.detach();
  
  const handler = Handler{ .allocator = allocator };
  //var server = try httpz.Server(Handler).init(allocator, .{ .port = PORT }, Handler{});
  var server = try httpz.Server(Handler).init(allocator, .{ .port = PORT }, handler);
  defer server.deinit();
  defer server.stop();
  
  var router = try server.router(.{});
  router.get("/", index, .{});
  router.get("/ws", ws_upgrade, .{});
  router.get("/static/*", serveStatic, .{}); // bert_ftp.js
  
  print("listening http://localhost:{d}/\n", .{ PORT });
  try server.listen(); // this is blocking
}

