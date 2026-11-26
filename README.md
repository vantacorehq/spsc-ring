<p align="center">
  <img src="https://img.shields.io/badge/LANGUAGE-Zig-F7A41D?style=for-the-badge&logo=zig" alt="Lang">
  <img src="https://img.shields.io/badge/FALSE--SHARING-PROTECTED-FFFFFF?style=for-the-badge" alt="Cache">
  <img src="https://img.shields.io/badge/ORDERING-Acquire%2FRelease-333333?style=for-the-badge" alt="Order">
</p>

# spsc-ring

**Cache-line aware lock-free SPSC ring buffer + arena allocator** in pure Zig.

## Hardcore features

- **False-sharing protection** — `head` and `tail` live on separate cache lines (`align(std.atomic.cache_line)`).
- **Cached indexes** — producer and consumer keep local copies of the opposite index and only reload the atomic when the buffer looks full/empty. Typical 2–4× speedup.
- **Strict Acquire/Release** — data is written *before* the release store of the index; data is read *after* the acquire load. Correct on ARM64 and x86.
- **Bulk operations** — `pushSlice` / `popSlice` move many elements with a single index update.
- **Arena** — bump allocator with `reset()` that keeps the underlying memory, plus poison fill in Debug builds to catch use-after-free.

## Quick example

```zig
var rb = RingBuffer(u64, 1024).init();
_ = rb.push(42);
_ = rb.pushSlice(&[_]u64{ 1, 2, 3 });
const v = rb.pop();
```

## Build & test

```bash
zig build test
zig build
```

## Guarantees

| Property              | Guarantee                                      |
|-----------------------|------------------------------------------------|
| False sharing         | Separated by full cache line                   |
| Memory ordering       | Acquire / Release only (no SeqCst tax)         |
| Progress              | Wait-free on the uncontended path              |
| Arena safety (Debug)  | Poison on free / reset                         |
| Dependencies          | Only Zig std                                   |

## License

MIT
