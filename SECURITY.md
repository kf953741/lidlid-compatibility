# Security & Audit Guide

`LidLid Compatibility` is intentionally open-source under the **MIT License** so users and security reviewers can independently inspect every line of code that runs with elevated macOS privileges.

## Security Model

1. **Zero passwords in LidLid:** Approval uses Apple's native `SMAppService.daemon` API in macOS System Settings (`General -> Login Items & Extensions`).
2. **Mutual Apple-anchored XPC authentication:**
   - The daemon validates Apple certificate provenance, Team ID (`63ALH54858`), and exact bundle identifier (`dev.kf.lidonce`, `dev.kf.lidonce.agent`, or `dev.kf.lidonce.compatibility`), then pins the validated CDHash onto the XPC connection before exporting any object.
   - Only the active console user (`SCDynamicStoreCopyConsoleUser`) is accepted.
   - The client independently pins the Developer ID daemon requirement (`CompatibilityService.daemonRequirement`).
   - Ad-hoc builds are deliberately rejected over XPC.
3. **Minimal fixed surface:** Only five XPC operations exist (`status`, `beginSession`, `renewSession`, `endSession`, `prepareForRemoval`). No shell invocation, caller-supplied paths, sudoers edits, or network sockets exist.
4. **Crash-safe sleep restoration:**
   - Before toggling system-wide `SleepDisabled`, the daemon atomically writes a root-owned `0600` recovery journal inside a `0700` directory using `openat` + `O_NOFOLLOW` + `F_FULLFSYNC` + `renameat`.
   - Every session uses a **30-second continuous-clock lease** renewed every 5 seconds. Disconnection, timeout, reopening the lid, battery <=10% on battery, thermal pressure, SIGTERM/SIGINT, or daemon restart automatically restores the exact original `SleepDisabled` value before clearing the journal.
   - Pre-existing `SleepDisabled=1` overrides from other tools are refused rather than overwritten.

## Emergency Sleep Recovery

If the helper was deleted improperly while sleep was disabled, run in Terminal:

```sh
sudo pmset -a disablesleep 0
```

## Reporting a Security Issue

Please email security reports privately to **lidlid@bigsmart.cc**.
