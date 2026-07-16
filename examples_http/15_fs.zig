const std = @import("std");
const httpz = @import("httpz");

const PORT = 8801;

// fs example - serve a folder of static files


var static_dir: std.fs.Dir = undefined;


fn index(_: *httpz.Request, res: *httpz.Response) !void {
  res.content_type = .HTML;
  res.body =
\\<!DOCTYPE html>
\\<html>
\\<head>
\\<meta charset="UTF-8">
\\<title>httpz serve static example</title>
\\</head>
\\<body>
\\<h1>Hello, World!</h1>
\\<script src="/static/site.js"></script>
\\</body>
\\</html>
;
}


fn serveStatic(req: *httpz.Request, res: *httpz.Response) !void {
  // req.url.path == "/static/site.js" // "/static/css/site.css"
  const prefix = "/static/";
  const path = req.url.path;

  if (!std.mem.startsWith(u8, path, prefix)) {
    res.status = 404;
    return;
  }

  var sub_path = path[prefix.len..];
  if (sub_path.len == 0) sub_path = "index.html";

  if (std.mem.indexOf(u8, sub_path, "..") != null) { // reject any attempt to escape the static root
    res.status = 400;
    res.body = "invalid path";
    return;
  }

  const max_size = 10 * 1024 * 1024; // 10MB
  const data = static_dir.readFileAlloc(res.arena, sub_path, max_size) catch |err| switch (err) {
    error.FileNotFound => {
      res.status = 404;
      res.body = "not found";
      return;
    },
    else => return err,
  };

  res.content_type = httpz.ContentType.forFile(sub_path);
  res.body = data;
}


pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();

  static_dir = try std.fs.cwd().openDir("static", .{});
  defer static_dir.close();

  var server = try httpz.Server(void).init(allocator, .{ .port = PORT }, {});
  defer server.deinit();
  defer server.stop();

  var router = try server.router(.{});
  router.get("/", index, .{});
  router.get("/static/*", serveStatic, .{});

  std.debug.print("listening http://localhost:{d}/\n", .{PORT});
  try server.listen();
}

