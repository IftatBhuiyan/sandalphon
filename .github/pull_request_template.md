## What this changes

## Why

## Checks

- [ ] `swift test -c release` passes
- [ ] For engine changes: `scripts/benchmark.sh` numbers before and after are included above
- [ ] Nothing on the key thread touches disk, network or another process
- [ ] Nothing typed is logged or stored
