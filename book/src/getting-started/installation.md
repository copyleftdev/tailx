# Installation

## Requirements

- **Zig 0.14.0** (no other dependencies)
- Any POSIX system (Linux, macOS)
- No libc required. No runtime. No garbage collector.

## Build from source

```bash
git clone https://github.com/your-org/tailx.git
cd tailx
zig build -Doptimize=ReleaseSafe
```

The binary lands in `zig-out/bin/tailx`. Copy it wherever you like:

```bash
cp zig-out/bin/tailx ~/.local/bin/
```

## Build variants

| Mode | Command | Binary size | Notes |
|------|---------|-------------|-------|
| Debug | `zig build` | ~3 MB | Safety checks, slow |
| ReleaseSafe | `zig build -Doptimize=ReleaseSafe` | 3.1 MB | Safety checks, fast |
| ReleaseSmall | `zig build -Doptimize=ReleaseSmall` | 144 KB | Stripped, production |
| ReleaseFast | `zig build -Doptimize=ReleaseFast` | ~2.8 MB | Max speed, no safety |

For production use, `ReleaseSafe` is recommended. For resource-constrained environments (containers, embedded), `ReleaseSmall` produces a 144 KB binary that fits in L2 cache.

## Run tests

```bash
zig build test
```

This runs all 219 tests across every module: core types, parsers, statistical structures, anomaly detectors, correlation engine, filters, and renderers. All tests pass in under 2 seconds.

## Verify installation

```bash
tailx --version
# tailx v1.0.0

tailx --help
# Shows usage, modes, filters, options
```

## No dependencies

tailx uses the Zig standard library exclusively. There are zero external dependencies -- no PCRE, no libc (where avoidable), no vendored C code. The entire binary is self-contained.
