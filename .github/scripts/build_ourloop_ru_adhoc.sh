#!/bin/bash

set -Eeuo pipefail
umask 077

for secret_name in ADHOC_P12_BASE64 ADHOC_P12_PASSWORD ADHOC_MOBILEPROVISION_BASE64; do
  if [[ -z "${!secret_name:-}" ]]; then
    echo "::error::Required GitHub Secret ${secret_name} is missing."
    exit 2
  fi
done

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

secret_dir="$(mktemp -d "${RUNNER_TEMP}/ourloop-adhoc-secrets.XXXXXX")"
build_dir="$(mktemp -d "${RUNNER_TEMP}/ourloop-adhoc-build.XXXXXX")"
keychain_path="${secret_dir}/ourloop-build.keychain-db"
keychain_password="$(openssl rand -base64 32)"
p12_path="${secret_dir}/certificate.p12"
profile_path="${secret_dir}/profile.mobileprovision"
profile_plist="${secret_dir}/profile.plist"
profile_metadata_dir="${secret_dir}/profile-metadata"
entitlements_path="${secret_dir}/OurLoopRU.entitlements"
identities_path="${secret_dir}/identities.txt"
signed_entitlements_path="${secret_dir}/signed-entitlements.plist"
archive_path="${build_dir}/OurLoopRU.xcarchive"
package_dir="${build_dir}/package"
artifacts_dir="${GITHUB_WORKSPACE}/artifacts"
ipa_path="${artifacts_dir}/OurLoop-RU-AdHoc.ipa"

cleanup() {
  security delete-keychain "${keychain_path}" >/dev/null 2>&1 || true
  rm -rf "${secret_dir}" "${build_dir}"
}
trap cleanup EXIT

mkdir -p "${profile_metadata_dir}" "${artifacts_dir}"
rm -f "${ipa_path}"

printf '%s' "${ADHOC_P12_BASE64}" | /usr/bin/base64 -D > "${p12_path}"
printf '%s' "${ADHOC_MOBILEPROVISION_BASE64}" | /usr/bin/base64 -D > "${profile_path}"
chmod 600 "${p12_path}" "${profile_path}"
unset ADHOC_P12_BASE64 ADHOC_MOBILEPROVISION_BASE64

security cms -D -i "${profile_path}" > "${profile_plist}"

python3 - "${profile_plist}" "${profile_metadata_dir}" "${entitlements_path}" <<'PY'
import datetime
import hashlib
import pathlib
import plistlib
import re
import sys


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(2)


profile_path = pathlib.Path(sys.argv[1])
metadata_dir = pathlib.Path(sys.argv[2])
entitlements_path = pathlib.Path(sys.argv[3])

with profile_path.open("rb") as profile_file:
    profile = plistlib.load(profile_file)

entitlements = profile.get("Entitlements")
if not isinstance(entitlements, dict):
    fail("The provisioning profile has no usable entitlements dictionary.")

expiration = profile.get("ExpirationDate")
if not isinstance(expiration, datetime.datetime):
    fail("The provisioning profile has no valid expiration date.")
now = datetime.datetime.now(expiration.tzinfo) if expiration.tzinfo else datetime.datetime.utcnow()
if expiration <= now:
    fail("The provisioning profile is expired.")

if profile.get("ProvisionsAllDevices") is True or not profile.get("ProvisionedDevices"):
    fail("The provisioning profile is not an Ad Hoc device profile.")
if entitlements.get("get-task-allow") is not False:
    fail("The provisioning profile is not an Ad Hoc distribution profile.")

team_ids = profile.get("TeamIdentifier") or []
app_prefixes = profile.get("ApplicationIdentifierPrefix") or []
if not team_ids or not app_prefixes:
    fail("The provisioning profile is missing signing-team metadata.")

team_id = team_ids[0]
app_prefix = app_prefixes[0]
application_identifier = entitlements.get("application-identifier")
if not isinstance(application_identifier, str) or not application_identifier.startswith(app_prefix + "."):
    fail("The provisioning profile has an invalid application identifier.")

bundle_identifier = application_identifier[len(app_prefix) + 1:]
identifier_pattern = re.compile(r"^[A-Za-z0-9.-]+$")
for value in (team_id, app_prefix, application_identifier, bundle_identifier):
    if not value or "*" in value or not identifier_pattern.fullmatch(value):
        fail("The provisioning profile must contain an explicit application identifier.")

profile_team_entitlement = entitlements.get("com.apple.developer.team-identifier")
if profile_team_entitlement not in (None, team_id):
    fail("The provisioning profile contains inconsistent team identifiers.")

if entitlements.get("com.apple.developer.healthkit") is not True:
    fail("The provisioning profile does not allow HealthKit.")
if entitlements.get("com.apple.developer.healthkit.background-delivery") is not True:
    fail("The provisioning profile does not allow HealthKit background delivery.")

nfc_formats = entitlements.get("com.apple.developer.nfc.readersession.formats")
if not isinstance(nfc_formats, list) or "TAG" not in nfc_formats:
    fail("The provisioning profile does not allow NFC tag reader sessions.")

app_groups = entitlements.get("com.apple.security.application-groups")
if not isinstance(app_groups, list) or not app_groups or not all(isinstance(group, str) for group in app_groups):
    fail("The provisioning profile does not contain an application group.")

expected_app_group = f"group.{bundle_identifier}"
if expected_app_group in app_groups:
    selected_app_group = expected_app_group
else:
    # With extensions removed, Loop needs one valid container but does not need to share it
    # with another executable. Prefer the conventional group when present; otherwise use
    # the first group authorized by the profile without exposing or hard-coding its value.
    selected_app_group = app_groups[0]
if (
    not selected_app_group.startswith("group.")
    or "*" in selected_app_group
    or not identifier_pattern.fullmatch(selected_app_group)
):
    fail("The provisioning profile contains an invalid application group.")

signed_entitlements = {
    "application-identifier": application_identifier,
    "com.apple.developer.team-identifier": team_id,
    "com.apple.developer.healthkit": True,
    "com.apple.developer.healthkit.background-delivery": True,
    "com.apple.developer.nfc.readersession.formats": nfc_formats,
    "com.apple.security.application-groups": [selected_app_group],
    "get-task-allow": False,
}

for optional_key in (
    "aps-environment",
    "com.apple.developer.healthkit.access",
    "com.apple.developer.usernotifications.time-sensitive",
):
    if optional_key in entitlements:
        signed_entitlements[optional_key] = entitlements[optional_key]

profile_keychain_groups = entitlements.get("keychain-access-groups")
if isinstance(profile_keychain_groups, list) and profile_keychain_groups:
    allowed = any(
        group == application_identifier
        or (isinstance(group, str) and group.endswith("*") and application_identifier.startswith(group[:-1]))
        for group in profile_keychain_groups
    )
    if not allowed:
        fail("The provisioning profile does not allow the app's default keychain group.")
    signed_entitlements["keychain-access-groups"] = [application_identifier]

developer_certificates = profile.get("DeveloperCertificates") or []
if not developer_certificates:
    fail("The provisioning profile has no signing certificates.")
certificate_hashes = [hashlib.sha1(bytes(certificate)).hexdigest().upper() for certificate in developer_certificates]

def write_private_text(name: str, value: str) -> None:
    destination = metadata_dir / name
    destination.write_text(value, encoding="utf-8")
    destination.chmod(0o600)


write_private_text("team-id.txt", team_id)
write_private_text("app-prefix.txt", app_prefix)
write_private_text("application-identifier.txt", application_identifier)
write_private_text("bundle-identifier.txt", bundle_identifier)
write_private_text("app-group.txt", selected_app_group)
write_private_text("profile-certificate-sha1.txt", "\n".join(certificate_hashes))
write_private_text(
    "mask-values.txt",
    "\n".join(dict.fromkeys([team_id, app_prefix, application_identifier, bundle_identifier, selected_app_group])),
)

with entitlements_path.open("wb") as entitlements_file:
    plistlib.dump(signed_entitlements, entitlements_file, fmt=plistlib.FMT_XML, sort_keys=True)
entitlements_path.chmod(0o600)
PY

while IFS= read -r private_value; do
  if [[ -n "${private_value}" ]]; then
    echo "::add-mask::${private_value}"
  fi
done < "${profile_metadata_dir}/mask-values.txt"

team_id="$(<"${profile_metadata_dir}/team-id.txt")"
bundle_identifier="$(<"${profile_metadata_dir}/bundle-identifier.txt")"
app_group="$(<"${profile_metadata_dir}/app-group.txt")"

security create-keychain -p "${keychain_password}" "${keychain_path}"
security set-keychain-settings -lut 21600 "${keychain_path}"
security unlock-keychain -p "${keychain_password}" "${keychain_path}"
security import "${p12_path}" -k "${keychain_path}" -P "${ADHOC_P12_PASSWORD}" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "${keychain_password}" "${keychain_path}" >/dev/null
security list-keychains -d user -s "${keychain_path}"
unset ADHOC_P12_PASSWORD

security find-identity -v -p codesigning "${keychain_path}" > "${identities_path}"
identity_sha="$(python3 - "${identities_path}" "${profile_metadata_dir}/profile-certificate-sha1.txt" <<'PY'
import pathlib
import re
import sys

identity_text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
allowed_hashes = set(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines())
available_hashes = re.findall(r"\b[0-9A-Fa-f]{40}\b", identity_text)
for candidate in available_hashes:
    normalized = candidate.upper()
    if normalized in allowed_hashes:
        print(normalized)
        raise SystemExit(0)
print("::error::The imported certificate is not allowed by the provisioning profile.", file=sys.stderr)
raise SystemExit(2)
PY
)"
echo "::add-mask::${identity_sha}"

cd "${GITHUB_WORKSPACE}"

xcodebuild \
  -resolvePackageDependencies \
  -workspace LoopWorkspace.xcworkspace \
  -scheme LoopWorkspace

xcodebuild \
  -workspace LoopWorkspace.xcworkspace \
  -scheme LoopWorkspace \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "${archive_path}" \
  MAIN_APP_BUNDLE_IDENTIFIER="${bundle_identifier}" \
  APP_GROUP_IDENTIFIER="${app_group}" \
  LOOP_DEVELOPMENT_TEAM="${team_id}" \
  DEVELOPMENT_TEAM="${team_id}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  archive

shopt -s nullglob
app_candidates=("${archive_path}/Products/Applications"/*.app)
shopt -u nullglob
if [[ ${#app_candidates[@]} -ne 1 ]]; then
  echo "::error::The unsigned archive does not contain exactly one iOS app."
  exit 2
fi
app_path="${app_candidates[0]}"

python3 - "${app_path}/Info.plist" "${bundle_identifier}" "${app_group}" <<'PY'
import pathlib
import plistlib
import sys

info_path = pathlib.Path(sys.argv[1])
expected_bundle_id = sys.argv[2]
expected_app_group = sys.argv[3]
with info_path.open("rb") as info_file:
    info = plistlib.load(info_file)

if info.get("CFBundleIdentifier") != expected_bundle_id:
    print("::error::The archived app bundle identifier does not match the provisioning profile.", file=sys.stderr)
    raise SystemExit(2)
if info.get("AppGroupIdentifier") != expected_app_group:
    print("::error::The archived app group does not match the provisioning profile.", file=sys.stderr)
    raise SystemExit(2)
if info.get("UIDeviceFamily") != [1]:
    print("::error::The archived app is not iPhone-only.", file=sys.stderr)
    raise SystemExit(2)
PY

if [[ ! -d "${app_path}/Frameworks/LibreTransmitterPlugin.framework" ]]; then
  echo "::error::The LibreTransmitter plugin is missing from the archived app."
  exit 2
fi

rm -rf "${app_path}/PlugIns" "${app_path}/Watch"
find "${app_path}" -type d -name '_CodeSignature' -prune -exec rm -rf {} +
cp "${profile_path}" "${app_path}/embedded.mobileprovision"

if find "${app_path}" -type d \( -name '*.appex' -o -name 'Watch' -o -name 'PlugIns' \) -print -quit | grep -q .; then
  echo "::error::An app extension or Watch payload remains in the diagnostic app."
  exit 2
fi

if [[ -d "${app_path}/Frameworks" ]]; then
  while IFS= read -r -d '' code_path; do
    codesign \
      --force \
      --sign "${identity_sha}" \
      --keychain "${keychain_path}" \
      --timestamp=none \
      --generate-entitlement-der \
      "${code_path}"
  done < <(find "${app_path}/Frameworks" -depth \( \( -type d -name '*.framework' \) -o \( -type f -name '*.dylib' \) \) -print0)
fi

codesign \
  --force \
  --sign "${identity_sha}" \
  --keychain "${keychain_path}" \
  --timestamp=none \
  --entitlements "${entitlements_path}" \
  --generate-entitlement-der \
  "${app_path}"

codesign --verify --deep --strict --verbose=2 "${app_path}"
codesign -d --entitlements :- "${app_path}" > "${signed_entitlements_path}" 2>/dev/null

python3 - "${entitlements_path}" "${signed_entitlements_path}" <<'PY'
import pathlib
import plistlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as expected_file:
    expected = plistlib.load(expected_file)
with pathlib.Path(sys.argv[2]).open("rb") as signed_file:
    signed = plistlib.load(signed_file)

for key, value in expected.items():
    if signed.get(key) != value:
        print("::error::The signed app entitlements do not match the validated provisioning subset.", file=sys.stderr)
        raise SystemExit(2)
PY

mkdir -p "${package_dir}/Payload"
ditto "${app_path}" "${package_dir}/Payload/Loop.app"
(
  cd "${package_dir}"
  /usr/bin/zip -qry "${ipa_path}" Payload
)

if [[ ! -s "${ipa_path}" ]]; then
  echo "::error::The Ad Hoc IPA was not created."
  exit 2
fi

{
  echo "### OurLoop RU Ad Hoc diagnostic IPA"
  echo "The iPhone-only IPA was built without App Store Connect or TestFlight."
  echo "Closed Loop and automatic dosing remain disabled by the diagnostic safety patch."
} >> "${GITHUB_STEP_SUMMARY}"
