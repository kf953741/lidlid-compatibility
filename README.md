# LidLid Compatibility · 盖盖兼容组件

**Open-source, auditable macOS compatibility helper for [LidLid · 盖盖](https://lidlid.bigsmart.cc).**

This repository contains the complete source code for `LidLid Compatibility.app` and its `SMAppService` root daemon (`LidLidSleepService`), published under the **MIT License** so anyone can inspect every line of privileged code before approving it in macOS System Settings.

> **Official signed & Apple-notarized download:** [https://lidlid.bigsmart.cc/support/#compatibility](https://lidlid.bigsmart.cc/support/#compatibility)
> **Main Mac App Store app & showcase:** [https://github.com/kf953741/lidlid](https://github.com/kf953741/lidlid) · [https://lidlid.bigsmart.cc](https://lidlid.bigsmart.cc)

---

## Why is this open-source?

The LidLid main app is distributed as a sandboxed **Mac App Store** app. To keep a MacBook awake with the lid closed on battery without an external display, macOS requires a separately installed, user-approved `LaunchDaemon` (`SMAppService.daemon`) to manage system-wide `SleepDisabled` via `/usr/bin/pmset` during active sessions.

Because users should never have to blindly trust a privileged helper, **100% of the privileged helper, XPC authentication, recovery journal, and lease watchdog code is open-source here**.

## What it does (and does not do)

- **Only 5 XPC calls:** `status`, `beginSession`, `renewSession`, `endSession`, `prepareForRemoval` (restricted to `LidLid Compatibility` + active console user).
- **Fixed `/usr/bin/pmset` calls only:** no shell, no `sudoers`, no network requests, no analytics, no reading of your files or AI conversations.
- **Mutual Apple-anchored signature & CDHash pinning:** prevents unauthorized local processes or ad-hoc binaries from talking to the daemon.
- **30-second continuous-clock lease + synced root journal:** automatically restores your exact original `SleepDisabled` setting on lid reopen, timeout, low battery (<=10%), thermal cutoff, disconnect, or reboot.
- **Universal macOS binary:** supports both Apple Silicon (`arm64`) and Intel (`x86_64`) MacBooks on macOS 14+.

## Build & Verify Locally

```sh
# 1. Run all unit tests (lease, crash recovery, journal atomicity, XPC auth)
swift test

# 2. Build Universal bundle (ad-hoc by default; XPC rejects ad-hoc builds)
zsh scripts/build-compatibility.sh

# 3. Verify bundle layout, entitlements, LaunchDaemon plist, and pmset parser self-test
python3 scripts/verify-compatibility.py "dist/LidLid Compatibility.app"
```

Building and testing **never** register a root LaunchDaemon or modify system power settings.

## Architecture & Removal Docs

- English engineering notes: [docs/COMPATIBILITY-ENGINEERING.md](docs/COMPATIBILITY-ENGINEERING.md)
- 中文安装与安全说明：[docs/COMPATIBILITY.zh-CN.md](docs/COMPATIBILITY.zh-CN.md)
- Security model & reporting: [SECURITY.md](SECURITY.md)

## License

[MIT License](LICENSE) © 2026 Fei Kang.
