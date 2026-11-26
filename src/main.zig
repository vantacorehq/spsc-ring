const std = @import("std");
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const cache_line = std.atomic.cache_line;

/// Cache-line aware lock-free SPSC ring.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (!std.math.isPowerOfTwo(capacity)) @compileError("capacity must be power of two");
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
        head_futex: Atomic(u32) = Atomic(u32).init(0),

        pub fn init() Self { return .{}; }

        pub fn push(self: *Self, value: T) bool {
            const head = self.head.load(.unordered);
            const next = (head + 1) & mask;
            if (next == self.cached_tail) {
                self.cached_tail = self.tail.load(.acquire);
                if (next == self.cached_tail) return false;
            }
            self.buffer[head] = value;
            self.head.store(next, .release);
            _ = self.head_futex.fetchAdd(1, .release);
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
            const v = self.buffer[tail];
            self.tail.store((tail + 1) & mask, .release);
            return v;
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

        /// Hybrid wait: short spin then futex.
        pub fn popWait(self: *Self, spin_iters: usize) T {
            var i: usize = 0;
            while (true) {
                if (self.pop()) |v| return v;
                if (i < spin_iters) {
                    std.atomic.spinLoopHint();
                    i += 1;
                } else {
                    const expected = self.head_futex.load(.acquire);
                    if (self.pop()) |v| return v;
                    std.Thread.Futex.wait(&self.head_futex, expected);
                    i = 0;
                }
            }
        }

        pub fn len(self: *const Self) usize {
            return (self.head.load(.unordered) -% self.tail.load(.unordered)) & mask;
        }
    };
}

/// Variable-length framed ring (zero-copy reserve/commit).
pub fn FramedRing(comptime capacity: usize) type {
    comptime {
        if (!std.math.isPowerOfTwo(capacity)) @compileError("capacity must be power of two");
    }
    return struct {
        const Self = @This();
        const mask: usize = capacity - 1;

        head: Atomic(usize) align(cache_line) = Atomic(usize).init(0),
        _pad1: [cache_line - @sizeOf(Atomic(usize))]u8 = undefined,
        tail: Atomic(usize) align(cache_line) = Atomic(usize).init(0),
        _pad2: [cache_line - @sizeOf(Atomic(usize))]u8 = undefined,
        buffer: [capacity]u8 = undefined,

        pub fn init() Self { return .{}; }

        /// Reserve contiguous space for a message of `len` bytes.
        /// Returns a writable slice inside the ring or null.
        pub fn reserve(self: *Self, len: usize) ?[]u8 {
            const total = 4 + len;
            const head = self.head.load(.unordered);
            const tail = self.tail.load(.acquire);
            const used = (head -% tail) & mask;
            if (used + total >= capacity) return null;
            if (head + total > capacity) return null; // require contiguous

            const len_ptr: *u32 = @ptrCast(@alignCast(&self.buffer[head]));
            len_ptr.* = @intCast(len);
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
            const len_ptr: *const u32 = @ptrCast(@alignCast(&self.buffer[tail]));
            const len = len_ptr.*;
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
        if (std.debug.runtime_safety) @memset(self.buffer, poison);
        self.underlying.free(self.buffer);
    }
    pub fn reset(self: *Arena) void {
        if (std.debug.runtime_safety) @memset(self.buffer[0..self.offset], poison);
        self.offset = 0;
    }
    pub fn allocator(self: *Arena) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const am = (@as(usize, 1) << @intCast(ptr_align)) - 1;
        const aligned = (self.offset + am) & ~am;
        if (aligned + len > self.buffer.len) return null;
        const p = self.buffer.ptr + aligned;
        self.offset = aligned + len;
        return p;
    }
    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool { return false; }
    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {}
};

test "fixed + framed" {
    var rb = RingBuffer(u64, 32).init();
    try std.testing.expect(rb.push(42));
    try std.testing.expectEqual(@as(?u64, 42), rb.pop());

    var fr = FramedRing(4096).init();
    if (fr.reserve(5)) |buf| {
        @memcpy(buf, "hello");
        fr.commit(5);
    } else unreachable;
    if (fr.read()) |msg| {
        try std.testing.expectEqualStrings("hello", msg);
        fr.advance(msg.len);
    } else unreachable;
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try out.print("spsc-ring — framed zero-copy + hybrid wait ready\n", .{});
    var rb = RingBuffer(u64, 64).init();
    _ = rb.pushSlice(&[_]u64{ 1, 2, 3 });
    while (rb.pop()) |v| try out.print("{d} ", .{v});
    try out.print("\n", .{});
}
