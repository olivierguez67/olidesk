# Client deployment (auto-registration)

Olidesk client builds (the stripped-down, receive-only flavor — see
`build.py --client`) don't show the address book, so there's no way to add
a deployed machine to it by hand. Instead, a client can self-register into
the address book, under a chosen group, using a short **enrollment code**
minted from the admin app.

This lets you hand someone a single installer per site/customer plus a
short code, and have every machine it's installed on show up in the right
group automatically — no manual address-book entry per machine, and no
secret baked into the installer itself.

How it works, in short: on first launch, if the device isn't already
registered, the client either (a) reads an enrollment code out of
`olidesk-deploy.json` next to its own executable and registers silently, or
(b) if there's no such file (or it's missing a code), shows a **"Register
this device"** dialog asking for the code, a device name, and a group. In
both cases it waits for its RustDesk ID, then calls the address-book API's
`/api/clients/register` endpoint with that ID, hostname, OS, and group,
authenticated by the enrollment code. Once registration succeeds it
remembers that (so it won't repeat on later launches) and deletes the JSON
file if there was one. See `flutter/lib/common/olidesk_deploy.dart` (silent
path), `flutter/lib/common/widgets/olidesk_register_device.dart`
(interactive dialog), and `olidesk-api/app.py`'s `register_client` (server)
for the implementation.

The Windows MSI can write `olidesk-deploy.json` itself, for silent/scripted
installs — see "Silent install" below. No installer-side dialog exists
anymore: a plain interactive install with no MSI properties passed gets no
file at all, and the app's own dialog handles registration entirely on
first launch instead.

## One-time server setup

1. `olidesk-api/config.json` holds the live break-glass admin token, so
   it's gitignored and never committed. On the server, create it once from
   the example (a `git pull` never touches it after that):
   ```
   cd olidesk-api
   cp config.json.example config.json
   ```
2. Fill in a real value for `token` — a random string.
   - `token` is a **break-glass recovery credential, not a day-to-day admin
     token**. It can only call `/api/admin/devices` (list/add/revoke admin
     devices) — it cannot browse or edit the address book itself, and it
     cannot mint or manage enrollment codes. Its only job is bootstrapping
     the first admin device on a fresh server, and recovering access if
     every device token is ever lost. Store it somewhere safe and separate
     from normal admin use (a password manager, not a chat message); see
     "Admin device authentication" below for how day-to-day access actually
     works.
   - There's no `deploy_token` anymore — enrollment codes (below) replace
     it, minted per deployment batch from the admin app instead of a single
     long-lived secret living in `config.json` and every client MSI.
3. From inside `olidesk-api/` (where `docker-compose.yml` lives — its build
   context and volume paths are relative to that directory), bring the API
   up:
   ```
   docker compose up -d --build
   ```
   After a config-only change, `docker compose restart olidesk-api` is
   enough.

## Admin device authentication

Address book access (the admin build's Olidesk Address Book tab) is
per-device, not a single shared password. Each admin device — a laptop, an
admin's own install — gets its own token, stored only as a sha256 hash on
the server; the plaintext is shown exactly once, at creation time.

- **Bootstrapping a fresh server**: with no devices registered yet, open
  Address Book API Settings → **Manage admin devices** → **Add Device**,
  and paste the break-glass `token` from `config.json` into the API
  Settings token field first (it authenticates device-management calls,
  though never the address book itself). Name the device, copy the token
  it returns, and paste that into the token field instead — from then on
  this device uses its own credential.
- **Adding another admin's device**: from any already-registered device,
  Manage admin devices → Add Device → give it that person's device a name
  → copy the token and send it to them to paste into their own API
  Settings.
- **Revoking a device**: Manage admin devices → the trash icon next to it.
  Takes effect immediately — that device's next request 401s.
- **Hard cap of 4 active devices.** A 5th `Add Device` call is rejected
  until one is revoked.
- **Audit log**: every admin auth attempt (address book calls and
  `/api/admin/devices` calls, success and failure alike) is appended to
  `olidesk-api/data/admin_auth.log` on the server, one line per attempt
  with a timestamp, source IP, device name (or `-` for a failed attempt),
  and endpoint.

## Enrollment codes

Enrollment codes are short (`XXXX-XXXX`, 8 characters), expire 24 hours
after creation, and are individually revocable — minted from an already
set-up admin device, not a long-lived secret shared across every install.
A code is reusable (not single-use) within its lifetime, so one code
typically covers a whole deployment batch (a site, a customer).

- **Minting a code**: Address Book API Settings → **Manage enrollment
  codes** → **New Code**. Copy it — it's still visible later in the list
  (unlike an admin device token), but the dialog is the easiest place to
  grab it right after creating it.
- **Using a code**: give it to whoever is deploying. They either type it
  into the client's "Register this device" dialog on first launch, or pass
  it as `ENROLLCODE="XXXX-XXXX"` to a silent `msiexec` install (see below).
- **Revoking a code**: Manage enrollment codes → the block icon next to it.
  Takes effect immediately.
- Rate limited to 20 registrations per hour per code (429 past that,
  independently per code — not a single fleet-wide limit), and every
  accepted call is logged (IP, hostname, group, timestamp) in the
  `registration_events` table in the address-book database.
- `GET /api/deploy/groups` (used by the "Register this device" dialog to
  populate its group dropdown once a code validates) also accepts an
  enrollment code, and only that — it 401s an admin device token, and
  returns nothing but top-level group names.

## Installing the client

The client MSI (`olidesk-client-*.msi`, built by
`.github/workflows/client-build.yml`) has `api_url` baked in at build
time (not a secret — just the server hostname) but **no enrollment code or
any other credential**. There's nothing sensitive in the installer file
itself; codes are handed out separately, per deployment.

**Interactive install**: install normally, with no special command-line
properties. On first launch, the app's own **"Register this device"**
dialog appears (unless the machine already registered on a previous
launch): type the enrollment code, confirm or edit the device name
(pre-filled with the hostname), and pick a group from the dropdown — which
populates once the code validates — or add a new one. **Register** submits
it; **Skip** closes the dialog for this run (it's offered again next
launch if the device still isn't registered, same as a failed silent
registration retries next launch).

**Silent install**: pass `ENROLLCODE`, and optionally `GROUP`/`DEVICENAME`,
as plain MSI properties —
```
msiexec /i olidesk-client-1.4.99-x86_64.msi ENROLLCODE="XXXX-XXXX" GROUP="ASPEN GROUP" DEVICENAME="Reception PC" /qn
```
The installer writes these into `olidesk-deploy.json` in the install
folder (nothing installer-side ever calls the network — no dialog, no
group-list fetch at install time), and first launch registers silently
using that file, with the same retry-on-failure behavior and log file as
the interactive dialog. Omit `DEVICENAME` and it still defaults to the
hostname; omit `GROUP` and the client registers with no group. Omit
`ENROLLCODE` entirely and no file gets written at all — the install
behaves exactly like a plain interactive one, and the app's own dialog
handles registration on first launch instead.

This only applies to the MSI. The portable/self-extracting EXE has no
install-time properties to set — use the manual approach below, or just
let the app's own dialog handle it on first launch. An admin-build MSI
never writes a deploy file either way (`api_url` is only baked in for the
client build) — it has no client-side registration flow at all.

## Manual: placing olidesk-deploy.json by hand

For the portable EXE, or any case where passing MSI properties at install
time isn't convenient and you'd rather not use the interactive dialog.

1. Get the client installer for the version you want to deploy — either
   download it from the GitHub release for that tag, or build it yourself
   with `build.py --client` (see `.github/workflows/client-build.yml` for
   the exact flags per platform).
2. Mint an enrollment code (see "Enrollment codes" above) and create
   `olidesk-deploy.json`:
   ```json
   {
     "api_url": "https://olidesk.olisys.co.il",
     "enroll_code": "XXXX-XXXX",
     "group": "ASPEN GROUP",
     "device_name": "Reception PC"
   }
   ```
   `group` is matched case-insensitively against existing top-level groups
   and created automatically if it doesn't exist yet — no need to
   pre-create it in the address book. `device_name` is optional; the client
   falls back to its own hostname when it's absent.
3. Put the installer and `olidesk-deploy.json` together (USB stick, network
   share, whatever's convenient). One JSON file per group/site — reuse the
   same installer and code for all of them, as long as the code hasn't
   expired or been revoked.

Where the file needs to end up depends on which installer you're using,
because the client reads it from the same folder as its own running
executable (`Platform.resolvedExecutable`'s parent directory):

- **MSI install** (the default `--app-name Olidesk` build): the installer
  always places the app at exactly this literal path:
  ```
  C:\Program Files\Olidesk\
  ```
  so the deploy config must be here:
  ```
  C:\Program Files\Olidesk\olidesk-deploy.json
  ```
  Run the MSI first, *then* copy `olidesk-deploy.json` into that folder —
  copying it there before installing does nothing, since the installer
  doesn't pick up extra files from wherever you ran it from. (Not a
  concern with `ENROLLCODE=...` on the command line above, which writes the
  file itself after the install folder is created.)
- **Portable/self-extracting EXE**: copy `olidesk-deploy.json` into the
  same folder as the portable EXE *before* running it, so it's sitting next
  to it the first time it launches (wherever that folder is — USB stick,
  network share, etc.).

Then just launch Olidesk. Registration happens silently in the
background — no UI, nothing to click, as long as the code is valid. If it
can't reach the API yet (no network on first boot, DNS not ready, etc.), or
the code turns out to be invalid/expired, it retries on the next launch;
if it still isn't registered by then, the interactive dialog takes over.

## Verifying / troubleshooting

Every run writes a plain-text log, timestamped line by line: file found or
not, config parsed or not, whether/when a RustDesk id showed up, the exact
HTTP request and response (never the enrollment code itself). Check it
first — it's the fastest way to see exactly where things stopped:

- Normally: `C:\Program Files\Olidesk\olidesk-deploy.log`, right next to
  the JSON file.
- If that folder isn't writable by the signed-in user (common for a
  non-admin user under `C:\Program Files`), it falls back to:
  `%APPDATA%\Olidesk\olidesk-deploy.log`, i.e.
  `C:\Users\<user>\AppData\Roaming\Olidesk\olidesk-deploy.log`.

Other things to check:

- Once registered, the client appears under the given group in the admin
  build's address book tab, `olidesk-deploy.json` is gone from the install
  folder (if there was one), and the log's last line reads "registered
  successfully".
- A `olidesk-deploy.json` placed anywhere other than the installed app's
  own folder is invisible to the client — it just silently does nothing
  (there's no error for a missing file, by design, since a plain
  interactive install doesn't have one, and that's expected). This is the
  most common reason nothing happens for the manual/portable path: check
  the literal path above, not just "next to the installer".
- If a machine never shows up via the silent path, check that
  `olidesk-deploy.json` has valid `api_url` and `enroll_code` values, that
  the code hasn't expired (24h) or been revoked (Manage enrollment codes
  shows status), that the machine can reach `api_url` over HTTPS, and read
  the log for the exact HTTP status/body the server returned.
- Re-registering an ID that's already in the address book updates its
  hostname/platform/group in place rather than creating a duplicate, so
  it's safe to reuse the same deploy package/code if you reinstall a
  machine. If a machine's local settings were wiped and it gets a brand
  new RustDesk id on reinstall (see "Uninstalling" below), the server
  matches it to its existing entry by hostname instead of creating a
  second one, as long as the hostname hasn't changed.

## Uninstalling

Uninstalling asks whether to keep or wipe this machine's Olidesk settings
(device ID, registration state, local config/logs) — kept by default, so a
routine reinstall (repair, version bump via a manual uninstall+install
instead of the MSI's own upgrade handling, etc.) doesn't lose its identity
and silently re-register as a "new" device. Wipe it deliberately when you
actually want a clean slate, e.g. repurposing a machine.

- **From an elevated MSI file** (`msiexec /x olidesk-client-1.4.99-x86_64.msi`)
  **or the command line in general**: a small native prompt appears (not a
  WiX dialog — see the comment in
  `res/msi/CustomActions/UninstallCleanup.cpp` for why) with a checkbox,
  checked by default. Cancel aborts the uninstall entirely, same as
  declining any other confirmation.
- **From Windows Settings → Apps**: the same prompt appears. WiX's own
  dialogs are well known not to show there even without a `/q` override on
  the uninstall string, but a native prompt shown directly from a custom
  action doesn't depend on that sequence at all, so it isn't affected.
- **Silent uninstall**: `msiexec /x {ProductCode} KEEPSETTINGS=0 /qn`
  wipes without any prompt; omit `KEEPSETTINGS` (or pass `KEEPSETTINGS=1`)
  to keep, also without a prompt. A genuinely silent uninstall
  (`/qn` with no `KEEPSETTINGS` override at all) defaults to keeping
  settings rather than showing a dialog an unattended script isn't
  expecting.

Wiping removes, machine-wide: every user profile's
`%APPDATA%\Olidesk` (config, device ID/keypair, local options), the
Windows service's own copy under
`C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\Olidesk`,
`C:\ProgramData\Olidesk` (including any recordings), and the app's
`HKLM\SOFTWARE\Classes\.olidesk`/`olidesk` registry keys. It does not
touch anything under `C:\ProgramData\RustDesk\` (a separate, unrebranded
staging path the app itself already treats as unsafe to delete) or the
`SoftwareSASGeneration` system policy value (unrelated to device identity).
