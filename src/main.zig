const std = @import("std");
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;

/// Lock-free SPSC ring buffer (power-of-two capacity).
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    if (comptime !std.math.isPowerOfTwo(capacity)) {
        @compileError("capacity must be a power of two");
    }
    return struct {
        const Self = @This();
        const mask: usize = capacity - 1;

        buffer: [capacity]T = undefined,
        head: Atomic(usize) = Atomic(usize).init(0),
        tail: Atomic(usize) = Atomic(usize).init(0),

        pub fn init() Self {
            return .{};
        }

        pub fn push(self: *Self, value: T) bool {
            const head = self.head.load(.unordered);
            const next = (head + 1) & mask;
            if (next == self.tail.load(.acquire)) return false;
            self.buffer[head] = value;
            self.head.store(next, .release);
            return true;
        }

        pub fn pushSlice(self: *Self, items: []const T) usize {
            var n: usize = 0;
            for (items) |v| {
                if (!self.push(v)) break;
                n += 1;
            }
            return n;
        }

        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.unordered);
            if (tail == self.head.load(.acquire)) return null;
            const value = self.buffer[tail];
            self.tail.store((tail + 1) & mask, .release);
            return value;
        }

        pub fn popSlice(self: *Self, out: []T) usize {
            var n: usize = 0;
            while (n < out.len) {
                if (self.pop()) |v| {
                    out[n] = v;
                    n += 1;
                } else break;
            }
            return n;
        }

        pub fn len(self: *const Self) usize {
            const h = self.head.load(.unordered);
            const t = self.tail.load(.unordered);
            return (h -% t) & mask;
        }
    };
}

/// Simple bump arena.
pub const Arena = struct {
    underlying: Allocator,
    buffer: []u8,
    offset: usize = 0,

    pub fn init(u: Allocator, size: usize) !Arena {
        return .{ .underlying = u, .buffer = try u.alloc(u8, size) };
    }

    pub fn deinit(self: *Arena) void {
        self.underlying.free(self.buffer);
        self.* = undefined;
    }

    pub fn reset(self: *Arena) void {
        self.offset = 0;
    }

    pub fn allocator(self: *Arena) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .free = free, .remap = remap } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const align_amt = alignment.toByteUnits();
        const aligned = std.mem.alignForward(usize, self.offset, align_amt);
        if (aligned + len > self.buffer.len) return null;
        const ptr = self.buffer.ptr + aligned;
        self.offset = aligned + len;
        return ptr;
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
};

test "ring basic" {
    var rb = RingBuffer(u32, 16).init();
    try std.testing.expect(rb.push(10));
    try std.testing.expect(rb.push(20));
    try std.testing.expectEqual(@as(?u32, 10), rb.pop());
    try std.testing.expectEqual(@as(?u32, 20), rb.pop());
    try std.testing.expect(rb.pop() == null);
}

test "ring bulk" {
    var rb = RingBuffer(u32, 16).init();
    const n = rb.pushSlice(&[_]u32{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(usize, 4), n);
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), rb.popSlice(&out));
    try std.testing.expectEqual(@as(u32, 1), out[0]);
    try std.testing.expectEqual(@as(u32, 4), out[3]);
}

test "arena" {
    var arena = try Arena.init(std.testing.allocator, 1024);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try a.alloc(u8, 64);
    @memset(s, 0x11);
    try std.testing.expect(s[0] == 0x11);
    arena.reset();
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try out.print("spsc-ring ready\n", .{});
    var rb = RingBuffer(u64, 32).init();
    _ = rb.pushSlice(&[_]u64{ 7, 8, 9 });
    while (rb.pop()) |v| {
        try out.print("{d} ", .{v});
    }
    try out.print("\n", .{});
}
