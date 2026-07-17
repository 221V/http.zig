const std = @import("std");
const httpz = @import("httpz");

//const PORT = 8801;


// listen Unix domain socket, Linux/macOS/BSD only


fn index(_: *httpz.Request, res: *httpz.Response) !void {
  res.body = "This is an HTTP over Unix-socket example";
}


pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();

  const socket_path = "/tmp/httpz.sock";

  var server = try httpz.Server(void).init(allocator, .{
    .unix_path = socket_path,
  }, {});
  defer server.deinit();
  defer server.stop();
  defer std.fs.deleteFileAbsolute(socket_path) catch {};

  var router = try server.router(.{});
  router.get("/", index, .{});

  std.debug.print("listening on unix socket {s}\n", .{socket_path});
  std.debug.print("try: curl --unix-socket {s} http://localhost/\n", .{socket_path});
  try server.listen();
}

