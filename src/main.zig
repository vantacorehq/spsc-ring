const std = @import("std");
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const cache_line = std.atomic.cache_line;

pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    if (!std.math.isPowerOfTwo(capacity)) {
        @compileError("capacity must be a power of two");
    }
    return struct {
        const Self = @This();
        const mask: usize = capacity - 1;

        head: Atomic(usize) align(cache_line) = Atomic(usize).init(0),
        _pad1: [cache_line - @sizeOf(Atomic(usize))]u8 = undefined,
        tail: Atomic(usize) align(cache_line) = Atomic(usize).init(0),
        _pad2: [cache_line - @sizeOf(Atomic(usize))]u8 = undefined,

        buffer: [capacity]T = undefined,
        cached_tail: usize = 0,
        cached_head: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn push(self: *Self, value: T) bool {
            const head = self.head.load(.unordered);
            const next = (head + 1) & mask;
            if (next == self.cached_tail) {
                self.cached_tail = self.tail.load(.acquire);
                if (next == self.cached_tail) return false;
            }
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
            if (tail == self.cached_head) {
                self.cached_head = self.head.load(.acquire);
                if (tail == self.cached_head) return null;
            }
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

pub fn FramedRing(comptime capacity: usize) type {
    if (!std.math.isPowerOfTwo(capacity)) {
        @compileError("capacity must be a power of two");
    }
    return struct {
        const Self = @This();
        const mask: usize = capacity - 1;

        head: Atomic(usize) align(cache_line) = Atomic(usize).init(0),
        _pad1: [cache_line - @sizeOf(Atomic(usize))]u8 = undefined,
        tail: Atomic(usize) align(cache_line) = Atomic(usize).init(0),
        _pad2: [cache_line - @sizeOf(Atomic(usize))]u8 = undefined,
        buffer: [capacity]u8 = undefined,

        pub fn init() Self {
            return .{};
        }

        pub fn reserve(self: *Self, len: usize) ?[]u8 {
            const total = 4 + len;
            const head = self.head.load(.unordered);
            const tail = self.tail.load(.acquire);
            const used = (head -% tail) & mask;
            if (used + total >= capacity) return null;
            if (head + total > capacity) return null;

            const len_bytes = std.mem.asBytes(&@as(u32, @intCast(len)));
            @memcpy(self.buffer[head..][0..4], len_bytes);
            return self.buffer[head + 4 .. head + 4 + len];
        }

        pub fn commit(self: *Self, len: usize) void {
            const head = self.head.load(.unordered);
            self.head.store((head + 4 + len) & mask, .release);
        }

        pub fn read(self: *Self) ?[]const u8 {
            const tail = self.tail.load(.unordered);
            const head = self.head.load(.acquire);
            if (tail == head) return null;
            var len: u32 = 0;
            @memcpy(std.mem.asBytes(&len), self.buffer[tail..][0..4]);
            return self.buffer[tail + 4 .. tail + 4 + len];
        }

        pub fn advance(self: *Self, len: usize) void {
            const tail = self.tail.load(.unordered);
            self.tail.store((tail + 4 + len) & mask, .release);
        }
    };
}

pub const Arena = struct {
    underlying: Allocator,
    buffer: []u8,
    offset: usize = 0,
    const poison: u8 = 0xAA;

    pub fn init(u: Allocator, size: usize) !Arena {
        return .{ .underlying = u, .buffer = try u.alloc(u8, size) };
    }

    pub fn deinit(self: *Arena) void {
        if (@import("builtin").mode == .Debug) {
            @memset(self.buffer, poison);
        }
        self.underlying.free(self.buffer);
    }

    pub fn reset(self: *Arena) void {
        if (@import("builtin").mode == .Debug) {
            @memset(self.buffer[0..self.offset], poison);
        }
        self.offset = 0;
    }

    pub fn allocator(self: *Arena) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const align_mask = (@as(usize, 1) << @intCast(ptr_align)) - 1;
        const aligned = (self.offset + align_mask) & ~align_mask;
        if (aligned + len > self.buffer.len) return null;
        const ptr = self.buffer.ptr + aligned;
        self.offset = aligned + len;
        return ptr;
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {}
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

test "framed zero-copy" {
    var fr = FramedRing(4096).init();
    const slice = fr.reserve(5) orelse unreachable;
    @memcpy(slice, "hello");
    fr.commit(5);
    const msg = fr.read() orelse unreachable;
    try std.testing.expectEqualStrings("hello", msg);
    fr.advance(msg.len);
}

test "arena" {
    var arena = try Arena.init(std.testing.allocator, 1024);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try a.alloc(u8, 64);
    @memset(s, 0x11);
    arena.reset();
    const s2 = try a.alloc(u8, 32);
    try std.testing.expect(@intFromPtr(s2.ptr) >= @intFromPtr(arena.buffer.ptr));
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
