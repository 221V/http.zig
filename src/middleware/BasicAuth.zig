
// Sample Basic-Auth middleware

const std = @import("std");
const httpz = @import("../httpz.zig");

const BasicAuth = @This();

expected: []const u8,

pub fn init(config: Config) !BasicAuth {
  return .{ .expected = config.expected };
}

pub fn execute(self: *const BasicAuth, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
  if (req.header("authorization")) |value| {
    if (std.mem.eql(u8, value, self.expected)) {
      return executor.next();
    }
  }

  res.status = 401;
  res.header("WWW-Authenticate", "Basic realm=\"httpz-auth-example\"");
  res.body = "401 Unauthorized: Access Denied";
  // not calling executor.next() stops the chain here
}

pub const Config = struct {
  // full expected header value, e.g. "Basic YWRtaW46cGFzc3dvcmQ="
  expected: []const u8,
};

