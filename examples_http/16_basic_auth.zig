const std = @import("std");
const httpz = @import("httpz");

const BasicAuth = httpz.middleware.BasicAuth;

const PORT = 8801;

// basic auth example, with middleware

// admin:password base64-encoded -> YWRtaW46cGFzc3dvcmQ=


fn index(_: *httpz.Request, res: *httpz.Response) !void {
  res.content_type = .HTML;
  res.body =
\\<!DOCTYPE html>
\\<html>
\\<head>
\\<meta charset="UTF-8">
\\<title>httpz basic auth example</title>
\\</head>
\\<body>
\\<p><a href="/admin">/admin</a> requires Basic Auth (admin:password)
\\</body>
\\</html>
;
}


fn admin(_: *httpz.Request, res: *httpz.Response) !void {
  res.content_type = .HTML;
  res.body = "<h1>Admin Area</h1><p>Secret data: 42</p>";
}


pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();

  var server = try httpz.Server(void).init(allocator, .{ .port = PORT }, {});
  defer server.deinit();
  defer server.stop();

  const auth = try server.middleware(BasicAuth, .{
    .expected = "Basic YWRtaW46cGFzc3dvcmQ=",
  });

  var router = try server.router(.{});
  router.get("/", index, .{});

  // only /admin is protected: pass the middleware per-route instead of
  // setting router.middlewares (which would apply it to every route)
  router.get("/admin", admin, .{ .middlewares = &.{auth} });

  std.debug.print("listening http://localhost:{d}/\n", .{PORT});
  try server.listen();
}

