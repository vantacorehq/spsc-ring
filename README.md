<p align="center">
  <img src="https://img.shields.io/badge/LANGUAGE-Zig-F7A41D?style=for-the-badge&logo=zig" alt="Lang">
  <img src="https://img.shields.io/badge/FALSE--SHARING-PROTECTED-FFFFFF?style=for-the-badge" alt="Cache">
  <img src="https://img.shields.io/badge/ZERO--COPY-FRAMED-333333?style=for-the-badge" alt="ZeroCopy">
</p>

# spsc-ring

**Low-latency lock-free SPSC ring** with framed zero-copy messages and hybrid waiting.

## Features

- **Cache-line isolation** — `head` / `tail` on separate lines
- **Local index caching** — 2–4× less atomic traffic
- **Acquire / Release** only
- **Fixed-size API** — `push` / `pop` / `pushSlice` / `popSlice`
- **Framed variable-length API** — `reserve(len) → []u8` + `commit(len)` (zero-copy)
- **Hybrid wait** — short `spinLoopHint` then `std.Thread.Futex`
- **Arena** with `reset()` + Debug poison

## Example (framed zero-copy)

```zig
var fr = FramedRing(4096).init();
if (fr.reserve(5)) |buf| {
    @memcpy(buf, "hello");
    fr.commit(5);
}
if (fr.read()) |msg| {
    // msg is a direct slice into the ring — no copy
    fr.advance(msg.len);
}
```

## Guarantees

| Property              | Guarantee                                      |
|-----------------------|------------------------------------------------|
| False sharing         | Full cache-line separation                     |
| Ordering              | Acquire / Release                              |
| Variable messages     | Framed + zero-copy reserve/commit              |
| Waiting               | Spin → Futex (no 100 % CPU burn)               |
| Dependencies          | Only Zig std                                   |

## Build

```bash
zig build test
zig build
```

## License

MIT
