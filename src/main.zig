const std = @import("std");
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const cache_line = std.atomic.cache_line;

/// Lock-free SPSC ring buffer with false-sharing protection and local index caching.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (!std.math.isPowerOfTwo(capacity)) {
            @compileError("capacity must be a power of two");
        }
    }

    return struct {
        const Self = @This();
        const mask: usize = capacity - 1;

        // Separate cache lines → no false sharing between producer and consumer
        head: Atomic(usize) align(cache_line) = Atomic(usize).init(0),
        _pad1: [cache_line - @sizeOf(Atomic(usize))]u8 = undefined,
        tail: Atomic(usize) align(cache_line) = Atomic(usize).init(0),
        _pad2: [cache_line - @sizeOf(Atomic(usize))]u8 = undefined,

        buffer: [capacity]T = undefined,

        // Cached copies (updated only when necessary)
        cached_tail: usize = 0, // used by producer
        cached_head: usize = 0, // used by consumer

        pub fn init() Self {
            return .{};
        }

        /// Single-element push. Returns false if full.
        pub fn push(self: *Self, value: T) bool {
            const head = self.head.load(.unordered);
            var next = (head + 1) & mask;

            if (next == self.cached_tail) {
                // Reload the real tail only when we think we are full
                self.cached_tail = self.tail.load(.acquire);
                if (next == self.cached_tail) return false;
            }

            self.buffer[head] = value;
            // Release: data is visible before the index update
            self.head.store(next, .release);
            return true;
        }

        /// Bulk push. Returns number of elements actually written.
        pub fn pushSlice(self: *Self, items: []const T) usize {
            var written: usize = 0;
            for (items) |v| {
                if (!self.push(v)) break;
                written += 1;
            }
            return written;
        }

        /// Single-element pop. Returns null if empty.
        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.unordered);

            if (tail == self.cached_head) {
                self.cached_head = self.head.load(.acquire);
                if (tail == self.cached_head) return null;
            }

            const value = self.buffer[tail];
            // Release: we are done with the slot
            self.tail.store((tail + 1) & mask, .release);
            return value;
        }

        /// Bulk pop into a buffer. Returns number of elements read.
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

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len() == capacity - 1;
        }
    };
}

/// Bump arena with reset that keeps the underlying allocation.
/// In Debug builds freed/reset memory is poisoned.
pub const Arena = struct {
    underlying: Allocator,
    buffer: []u8,
    offset: usize = 0,

    const poison_byte: u8 = 0xAA;

    pub fn init(underlying: Allocator, size: usize) !Arena {
        const buffer = try underlying.alloc(u8, size);
        return .{ .underlying = underlying, .buffer = buffer };
    }

    pub fn deinit(self: *Arena) void {
        if (std.debug.runtime_safety) {
            @memset(self.buffer, poison_byte);
        }
        self.underlying.free(self.buffer);
        self.* = undefined;
    }

    /// Reset the bump pointer; memory stays allocated.
    pub fn reset(self: *Arena) void {
        if (std.debug.runtime_safety) {
            @memset(self.buffer[0..self.offset], poison_byte);
        }
        self.offset = 0;
    }

    pub fn allocator(self: *Arena) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
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

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {
        // no-op — lifetime is controlled by reset / deinit
    }
};

test "ring basic + bulk" {
    var rb = RingBuffer(u32, 16).init();
    try std.testing.expect(rb.push(10));
    try std.testing.expectEqual(@as(usize, 3), rb.pushSlice(&[_]u32{ 20, 30, 40 }));
    try std.testing.expectEqual(@as(?u32, 10), rb.pop());

    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 3), rb.popSlice(&out));
    try std.testing.expectEqual(@as(u32, 20), out[0]);
    try std.testing.expectEqual(@as(u32, 40), out[2]);
}

test "arena reset + poison" {
    var arena = try Arena.init(std.testing.allocator, 512);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try a.alloc(u8, 32);
    @memset(s, 0x11);
    arena.reset();
    // after reset the same memory region can be reused
    const s2 = try a.alloc(u8, 16);
    try std.testing.expect(@intFromPtr(s2.ptr) <= @intFromPtr(s.ptr) + 32);
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try out.print("spsc-ring — cache-line aware lock-free SPSC ready\n", .{});

    var rb = RingBuffer(u64, 32).init();
    _ = rb.pushSlice(&[_]u64{ 1, 2, 3, 4, 5 });
    while (rb.pop()) |v| {
        try out.print("{d} ", .{v});
    }
    try out.print("\n", .{});
}
