const std = @import("std");
const httpz = @import("httpz");

const PORT = 8801;

// form GET-POST handle example


const UserInfo = struct {
  fname: []const u8 = "",
  mname: []const u8 = "Middle",
  lname: []const u8 = "",
  age: []const u8 = "",
};


fn index(_: *httpz.Request, res: *httpz.Response) !void {
  res.content_type = .HTML;
  res.body =
\\<!DOCTYPE html>
\\<html>
\\<head>
\\<meta charset="UTF-8">
\\<title>httpz form example</title>
\\</head>
\\<body>
\\<form>
\\<label for="fname">First name:</label>
\\<input type="text" id="fname" name="fname"><br><br>
\\<label for="lname">Last name:</label>
\\<input type="text" id="lname" name="lname"><br><br>
\\<label for="age">Age:</label>
\\<input type="text" id="age" name="age"><br><br>
\\<button formaction="/generate" formmethod="get">Submit GET</button>
\\<button formaction="/generate" formmethod="post">Submit POST</button>
\\</form>
\\</body>
\\</html>
;
}


fn parseUserInfo(kv: *httpz.key_value.StringKeyValue) UserInfo {
  return .{
    .fname = kv.get("fname") orelse "",
    .mname = kv.get("mname") orelse "Middle",
    .lname = kv.get("lname") orelse "",
    .age = kv.get("age") orelse "",
  };
}


fn generate(req: *httpz.Request, res: *httpz.Response) !void {
  const kv = switch (req.method) {
    .GET => req.query() catch {
      res.status = 400;
      res.body = "Invalid or empty query parameters";
      return;
    },
    .POST => req.formData() catch {
      res.status = 400;
      res.body = "Invalid or empty form data";
      return;
    },
    else => return error.UnexpectedMethod,
  };

  const info = parseUserInfo(kv);
  const age = std.fmt.parseInt(u16, info.age, 10) catch 0;

  res.content_type = .TEXT;
  res.body = try std.fmt.allocPrint(
    res.arena,
    "First: {s} | Middle: {s} | Last: {s} | Age: {d}",
    .{
      if (info.fname.len == 0) "(empty)" else info.fname,
      info.mname,
      if (info.lname.len == 0) "(empty)" else info.lname,
      age,
    },
  );
}


pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();

  var server = try httpz.Server(void).init(allocator, .{
    .port = PORT,
    .request = .{
        .max_form_count = 20,
     },
  }, {});
  defer server.deinit();
  defer server.stop();

  var router = try server.router(.{});
  router.get("/", index, .{});
  router.get("/generate", generate, .{});
  router.post("/generate", generate, .{});

  std.debug.print("listening http://localhost:{d}/\n", .{PORT});
  try server.listen();
}

