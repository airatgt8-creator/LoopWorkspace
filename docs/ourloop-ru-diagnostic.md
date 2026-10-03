# OurLoop RU Libre 2 diagnostic build

This branch is for collecting diagnostics from a directly connected Libre 2 regional sensor. It is not validated for treatment decisions.

## Safety behavior

- Direct Libre readings are stored as display-only samples.
- `OURLOOP_RU_DIAGNOSTIC_MODE` is enabled in `LoopConfigOverride.xcconfig`.
- The build workflow applies `submodule-patches/ourloop-ru-diagnostic-safety.patch` to the pinned Loop submodule.
- The patch disables the Closed Loop control and adds a second hard check immediately before automatic dosing is enacted.
- The dosing algorithm itself is unchanged.
- MedtrumKit and the diagnostic Libre plugin remain available at their pinned revisions.
- The Ad Hoc IPA is iPhone-only. Apple Watch content, Widget Extension, Intent Extension, and Status Extension are removed before signing.
- The workflow never contacts App Store Connect and never uploads to TestFlight.

Do not remove the compilation condition or the safety patch until Libre 2 RU values have been compared with an approved meter/reader over a representative range and the change has received a separate review.

## Building the iPhone-only Ad Hoc IPA with GitHub Actions

Create exactly these repository Actions secrets:

- `ADHOC_P12_BASE64`: the Base64 representation of the Ad Hoc signing certificate `.p12` file;
- `ADHOC_P12_PASSWORD`: the password for that `.p12` file;
- `ADHOC_MOBILEPROVISION_BASE64`: the Base64 representation of the Ad Hoc `.mobileprovision` file.

No Team ID, bundle identifier, application group, device identifier, or App Store Connect secret is needed. The workflow extracts the signing values from the provisioning profile at runtime, masks them, and deletes all decoded signing files and the temporary keychain when the job ends.

On Windows PowerShell, create each Base64 value locally without modifying the original file:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\certificate.p12"))
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\profile.mobileprovision"))
```

Then:

1. Open the repository's **Settings → Secrets and variables → Actions** page and create the three secrets above.
2. Open **Actions → 4. Build Loop Manual**. This existing workflow path is used as the launcher because GitHub only exposes manual workflows that also exist on the default branch.
3. Choose **Run workflow**, select `ourloop-ru`, and run it. The branch implementation and resulting run are named **Build OurLoop RU AdHoc**.
4. Download the `OurLoop-RU-AdHoc-IPA` artifact and extract `OurLoop-RU-AdHoc.ipa`.
5. Install the IPA using an Ad Hoc-capable installer. It can install only on devices whose UDIDs are present in the provisioning profile.
6. Confirm on first launch that Closed Loop is unavailable and reports that automatic dosing is disabled in the Libre diagnostic build.

The workflow rejects expired, wildcard, development, App Store, or enterprise profiles. It also rejects profiles that do not allow HealthKit, HealthKit background delivery, NFC `TAG` reader sessions, and an application group.

## Building locally on a Mac

Clone the branch recursively, then apply the safety patch before opening the workspace:

```sh
git clone --branch=ourloop-ru --recurse-submodules https://github.com/airatgt8-creator/LoopWorkspace.git
cd LoopWorkspace
git -C Loop apply --unidiff-zero --check ../submodule-patches/ourloop-ru-diagnostic-safety.patch
git -C Loop apply --unidiff-zero ../submodule-patches/ourloop-ru-diagnostic-safety.patch
open LoopWorkspace.xcworkspace
```

Use the `LoopWorkspace` scheme only for development. The reproducible iPhone-only Ad Hoc packaging, extension removal, entitlement validation, and manual signing are implemented by the GitHub workflow.

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
