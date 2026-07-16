const std = @import("std");
const httpz = @import("httpz");

const PORT = 8801;

// SSE - Server-Sent-Events example


fn index(_: *httpz.Request, res: *httpz.Response) !void {
  res.content_type = .HTML;
  res.body =
\\<!DOCTYPE html>
\\<html>
\\<head>
\\<meta charset="UTF-8">
\\<title>httpz sse example</title>
\\</head>
\\<body>
\\<h1>SSE example</h1>
\\<div id="out"></div>
\\<script>
\\const out = document.getElementById('out');
\\const es = new EventSource('/stream');
\\es.onmessage = (e) => out.insertAdjacentHTML('beforeend', '<p>' + e.data + '</p>');
\\</script>
\\</body>
\\</html>
;
}


fn stream(_: *httpz.Request, res: *httpz.Response) !void {
  const stream_ = try res.startEventStreamSync(); // over the connection; from here on we write raw SSE frames
  const w = stream_.writer();

  var i: usize = 1;
  while (i < 11) : (i += 1) {
    w.print("data: hello from handler! ({d})\n\n", .{i}) catch break;
    std.time.sleep(1 * std.time.ns_per_s);
  }
}


fn message(_: *httpz.Request, res: *httpz.Response) !void {
  try res.json(.{ .id = 1, .message = "hello from post handler" }, .{});
}


pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();

  var server = try httpz.Server(void).init(allocator, .{ .port = PORT }, {});
  defer server.deinit();
  defer server.stop();

  var router = try server.router(.{});
  router.get("/", index, .{});
  router.get("/stream", stream, .{});
  router.post("/message", message, .{});

  std.debug.print("listening http://localhost:{d}/\n", .{PORT});
  try server.listen();
}

