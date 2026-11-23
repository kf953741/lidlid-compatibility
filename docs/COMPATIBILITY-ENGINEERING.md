# Closed-lid compatibility architecture

The commercial distribution target remains the Mac App Store. The Store app remains sandboxed. Version 1.5 also has an independent open-lid mode that requires no privileged component. The user independently installs a free, Developer ID signed and notarized compatibility app from the product website. Approval is requested by macOS Service Management, never by collecting a password in LidLid. App Review approval is not implied by this architecture.

## Cause and change

The November 1 failure happened before the November 2 macOS update. A display wake followed by WindowServer DMGrace expiry caused powerd to clear the shared selector-12 clamshell bit and immediately initiate Clamshell Sleep. Polling that bit faster cannot make ownership reliable. New sessions do not call selector 12.

The independently installed component registers a root LaunchDaemon through `SMAppService.daemon`. Its only operations are status, begin, renew, end, and prepare-for-removal. It runs `/usr/bin/pmset` with fixed arguments to read and temporarily set **system-wide** `SleepDisabled`. This is not a per-power-source setting; `pmset -g custom` is not an authoritative snapshot. See [Apple pmset source](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m).

## Boundaries and recovery

- The App Group-prefixed Mach service allows sandbox lookup without a temporary sandbox exception. The inherited worker shares the main sandbox. Client and service pin each other's Apple-anchored Team ID and bundle identifiers. Only the current console user's approved clients are accepted.
- There is one session owner per XPC connection; another connection cannot renew or cancel it. Removal explicitly pauses all new sessions before restoring. No generic shell, caller-supplied file path, sudoers rule, password storage, private power entitlement or remote service is exposed.
- A 30-second continuous-clock lease is renewed every 5 seconds. The worker's UI heartbeat timeout remains 12 seconds. Closed-lid mode owns no additional idle assertion. Optional open-lid mode uses a public PreventUserIdleSystemSleep assertion with TimeoutActionRelease after 30 seconds, renewed every 5 seconds; it releases on physical close/system sleep and never changes SleepDisabled. Neither hold can remain unbounded after a worker freeze. The daemon independently observes lid reopening, battery <=10% on battery, thermal pressure, sensor loss and optional duration. The worker additionally checks displays and the competing app. Clock adjustments do not extend daemon leases.
- Before mutation, the root daemon writes a root-owned 0600 recovery journal in a fixed 0700 directory using no-follow directory-relative operations, full file sync and rename. The journal contains only schema and the original boolean. Startup, termination, disconnect, expiry, removal and safety stops restore and read back the original setting before clearing the journal. Failed restoration retains the journal and retries.
- Existing `SleepDisabled=1` is refused; LidLid does not claim ownership of another utility's override. A different application's later change causes the session to stop rather than fight over settings. Concurrent external sleep controllers remain unsupported.
- This global setting temporarily prevents manual sleep as well. Users must turn LidLid off before choosing Sleep. Shutdown/forced power-off is not intercepted.

## Build and verify

### Apple re-signing and client authentication (component 1.0.1)

The installed TestFlight 1.6.1 (12) app and worker are signed by **TestFlight Beta Distribution**. Their leaf certificate does not carry our developer certificate's OU. Component 1.0.0 therefore rejected their XPC connections with `-67050`, even though their signed Team ID is still `63ALH54858`.

Component 1.0.1 validates Apple certificate provenance, the signed CodeDirectory Team ID, and the three explicit client signing identifiers. The Apple-owned TestFlight and Mac App Store certificate families are accepted alongside our developer certificate; a self-reported entitlement is never sufficient. After validation, each connection receives a requirement pinned to the validated identifier and CDHash **before** exporting an object or processing messages. The kernel checks this pin against XPC's original peer, so a PID reused during discovery cannot substitute a different executable. No private audit-token API or per-release hash allowlist is used. The client still pins the Developer ID daemon's identifier and signing team.

The local service test run passed 21 checks, including the actual Apple-distributed worker and running TestFlight process, a mismatched team, an unrelated Apple executable, and an ad-hoc impostor carrying forged team entitlements. Component 1.0.1 (2) is now installed with Developer ID signing. The actual TestFlight app successfully queried the running root service: `available=true`, `active=false`, `recoveryPending=false`. Launchd records validation category 6, and both installed executables match the uploaded candidate by SHA256. This records the live XPC connection check. StoreKit transaction acceptance is tracked separately in app-store/submission-status.json.

During the local development-to-distribution transition, launchd retained the old development-only spawn constraint (category 3) after the bundle was replaced. The old service had already restored sleep and removed its recovery journal, and the replacement had never started. A local-only, signed maintenance entry point used `SMAppService.unregister()` to remove that stale owned job; no production removal fallback was added. The bundle was replaced atomically and only this component's duplicate Launch Services registrations were removed before registering the canonical Developer ID app. This produced a running category-6 service without resetting unrelated background items or weakening code-signing checks. Keep development registrations isolated and do not assume a normal update can change certificate families in place.

The corrected archive was notarized as `1A2CC6AF-01E3-4B33-BDF1-A632E5748B3A` (build 2). Xcode reported Ready to distribute on November 7, 2026; its exported app passed deep/strict signature verification, stapled-ticket validation and Gatekeeper assessment as Notarized Developer ID. Xcode refreshed signatures during export: full binary hashes changed, while unsigned payload hashes matched the uploaded candidate for both executables. The installed candidate uses the same verified executable payload. New archives must not inherit a previous archive's `Distributions` metadata. The older build-1 job is not a release candidate.

The [component release](https://github.com/kf953741/lidlid/releases/download/compatibility-v1.0.1/LidLid-Compatibility-1.0.1-macOS-arm64.dmg) contains one DMG. Its mounted app passed signature, ticket and Gatekeeper checks, and remote download bytes matched SHA256 `139bb8a6b508e6b4eba45efc93f86edbe319f2c3a186d4feab2451fd48cb0b36`. The app inside the DMG is notarized and stapled; the outer DMG has no separate notarization submission.

To repeat the optional live identity check with an observed running Beta process:

```sh
LIDLID_TEST_BETA_PID=<observed-beta-process-id> swift test --filter LidLidServiceTests
```

`zsh scripts/build.sh` and `zsh scripts/build-compatibility.sh` create separate bundles. By default they use ad-hoc signatures: XPC deliberately rejects these signatures. Never distribute them as a working production component.

For local development, set `LIDLID_CODE_SIGN_IDENTITY` to an Apple Development identity for team `63ALH54858`. Use a matching Developer ID Application identity for external production distribution, enable hardened runtime, notarize the app and verify its stapled ticket from the final distribution container. Configure Store provisioning and App Group under the same team, sign the main app for App Store distribution, then validate through App Store Connect. Credentials/profiles must remain outside Git.

The compatibility app must be in `/Applications` before registering its bundled LaunchDaemon. Building and CI never register it or change power settings.

Checks:

```sh
swift test
# With the UI quit and lid open:
python3 scripts/integration-open-lid.py dist/LidLid.app/Contents/MacOS/LidLid
python3 scripts/verify-sandbox.py dist/LidLid.app
python3 scripts/verify-compatibility.py 'dist/LidLid Compatibility.app'
dist/LidLid.app/Contents/MacOS/LidLid --compatibility-status
# After explicit macOS service approval, UI quit, lid open and no external display:
python3 scripts/integration.py dist/LidLid.app/Contents/MacOS/LidLid
```

Unit tests use injected power/journal objects. They cover restoration failure, crash recovery, partial mutation, expiry, ownership, safety, deadlines and signature syntax. They do not establish root permissions, sandbox XPC reachability, physical lid behavior or App Review acceptance. Open-lid integration checks actual persistent state and restoration, including worker SIGKILL. Physical validation must additionally cover battery/no monitor, >10-second closed-lid display-wake regression, AC/battery transitions, normal subsequent lid sleep, and reboot/daemon restart recovery.

## Primary references

- [Apple App Review Guidelines, 2.4.5 and 2.5.1](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Service Management](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple code signing requirements and distribution channels](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)
- [Foundation peer code signing requirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
- [Apple powerd assertion policy](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/PMAssertions.c)
- [Apple root-domain user client](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/RootDomainUserClient.cpp)
- [Rouse Store listing](https://apps.apple.com/us/app/rouse-stay-awake/id6760773101?mt=12) and [public companion architecture](https://github.com/JaminZhou/Rouse-Closed-Lid-Helper), consulted as implementation references; no third-party helper code is bundled.

Open-lid assertion and timeout semantics are defined by [Apple IOPMLib.h](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLib.h). It prevents idle system sleep while allowing display, clamshell and manual sleep. No display assertion or fake user activity is used.
