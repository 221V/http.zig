const std = @import("std");
const httpz = @import("httpz");

const PORT = 8801;

// basic rest example, return different representation depending on the client's request header


const User = struct {
  id: u32,
  name: []const u8,
  email: []const u8,
};


fn index(_: *httpz.Request, res: *httpz.Response) !void {
  res.content_type = .HTML;
  res.body =
\\<!DOCTYPE html>
\\<html>
\\<head>
\\<meta charset="UTF-8">
\\<title>httpz rest content negotiation example</title>
\\</head>
\\<body>
\\<h3>httpz REST content negotiation</h3>
\\<select id="acceptType">
\\<option value="application/json">JSON</option>
\\<option value="text/html">HTML</option>
\\<option value="text/plain">Plain Text</option>
\\</select>
\\<button onclick="send()">Send Request</button>
\\<div id="view"></div>
\\<script>
\\async function send(){
\\  const type = document.getElementById('acceptType').value;
\\  const res = await fetch('/user', { headers: { 'Accept': type } });
\\  const contentType = res.headers.get('content-type');
\\  console.log('Response Received Type == ', contentType);
\\  const html_or_text = await res.text();
\\  const cont = document.getElementById('view');
\\  if(contentType.includes('html')){
\\    cont.insertAdjacentHTML('beforeend', html_or_text);
\\  }else{
\\    cont.insertAdjacentText('beforeend', html_or_text);
\\    cont.insertAdjacentHTML('beforeend', '<br>');
\\  }
\\}
\\</script>
\\</body>
\\</html>
;
}


fn user(req: *httpz.Request, res: *httpz.Response) !void {
  const the_user = User{ .id = 1, .name = "Alice", .email = "alice@example.com" };
  const accept = req.header("accept") orelse "*/*";

  if (std.mem.indexOf(u8, accept, "application/json") != null) {
    return res.json(the_user, .{});
  }

  if (std.mem.indexOf(u8, accept, "text/html") != null) {
    res.content_type = .HTML;
    res.body = try std.fmt.allocPrint(
      res.arena,
      "<p>User: {s} has ID: {d}</p>",
      .{ the_user.name, the_user.id },
    );
    return;
  }

  res.content_type = .TEXT;
  res.body = try std.fmt.allocPrint(
    res.arena,
    "User: {s} (ID: {d})",
    .{ the_user.name, the_user.id },
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
  router.get("/user", user, .{});

  std.debug.print("listening http://localhost:{d}/\n", .{PORT});
  try server.listen();
}

