# OurLoop RU Libre 2 diagnostic build

This branch is for collecting diagnostics from a directly connected Libre 2 regional sensor. It is not validated for treatment decisions.

## Safety behavior

- Direct Libre readings are stored as display-only samples.
- `OURLOOP_RU_DIAGNOSTIC_MODE` is enabled in `LoopConfigOverride.xcconfig`.
- The build workflow applies `submodule-patches/ourloop-ru-diagnostic-safety.patch` to the pinned Loop submodule.
- The patch disables the Closed Loop control and adds a second hard check immediately before automatic dosing is enacted.
- The dosing algorithm itself is unchanged.
- Apple Watch targets and MedtrumKit remain at the upstream-pinned revisions.

Do not remove the compilation condition or the safety patch until Libre 2 RU values have been compared with an approved meter/reader over a representative range and the change has received a separate review.

## Building with GitHub Actions

1. Open the `ourloop-ru` branch of the LoopWorkspace fork on GitHub.
2. Configure the normal Loop browser-build secrets and signing assets described in `fastlane/testflight.md`.
3. Open **Actions**, run **4. Build Loop Manual**, and select `ourloop-ru`.
4. Install the resulting TestFlight build using the normal Loop browser-build process.
5. Confirm on first launch that Settings says automatic dosing is disabled in the Libre diagnostic build.

## Building locally on a Mac

Clone the branch recursively, then apply the safety patch before opening the workspace:

```sh
git clone --branch=ourloop-ru --recurse-submodules https://github.com/airatgt8-creator/LoopWorkspace.git
cd LoopWorkspace
git -C Loop apply --unidiff-zero --check ../submodule-patches/ourloop-ru-diagnostic-safety.patch
git -C Loop apply --unidiff-zero ../submodule-patches/ourloop-ru-diagnostic-safety.patch
open LoopWorkspace.xcworkspace
```

Use the `LoopWorkspace` scheme. Signing and device installation otherwise follow the normal Loop instructions.

## Collecting a useful sensor trace

1. Keep the official Libre application and any other sensor reader disconnected during the test.
2. Add **FreeStyle Libre** and choose **Libre 2 Direct**.
3. Perform one NFC pairing scan, then leave Loop in the foreground for the first BLE connection.
4. Export the Loop issue report/device logs after a success or failure.
5. Search the log for `[LibreRU]`. The trace records:
   - UID and patchInfo byte lengths and hex values;
   - diagnostic sensor type, including C5/C6/7F variants;
   - NFC connect, system-info, FRAM-read, enable-streaming, and decrypt stages;
   - BLE discovery, unlock, frame assembly, decrypt, CRC, and reading-forward stages.

UID, patchInfo, MAC address, and raw protocol payloads identify the sensor and are intentionally logged for this diagnostic branch. Remove or redact them before sharing logs publicly.

## Real-sensor validation still required

- exact Libre 2 RU patchInfo and UID layout;
- NFC enable-streaming response and advertised BLE name/MAC behavior;
- BLE unlock acceptance across reconnects;
- 46-byte frame decryption and CRC validation;
- calibration extraction and glucose agreement against an approved reference;
- stability across sensor warm-up, normal use, signal loss, app restart, and sensor expiry.
