const std = @import("std");
const httpz = @import("httpz");

const PORT = 8801;

// cookies example


fn index(req: *httpz.Request, res: *httpz.Response) !void {
  const seen = req.cookies().get("example_cookie");
  std.log.debug("cookie: example_cookie={s}", .{seen orelse "(none)"});

  // set/refresh cookie for next time
  try res.setCookie("example_cookie", "abcdef123", .{
    .path = "/",
    .max_age = 3600, // 3600 sec = 1 hour
    .http_only = true,
    .same_site = .lax,
  });

  res.content_type = .HTML;
  res.body = try std.fmt.allocPrint(
    res.arena,
    "Hello, world! Previous cookie value: {s}",
    .{seen orelse "(none, this must be your first visit)"},
  );
}


pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();

  var server = try httpz.Server(void).init(allocator, .{ .port = PORT }, {});
  defer server.deinit();
  defer server.stop();

  var router = try server.router(.{});
  router.get("/", index, .{});

  std.debug.print("listening http://localhost:{d}/\n", .{PORT});
  try server.listen();
}

