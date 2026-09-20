# Client deployment (auto-registration)

Olidesk client builds (the stripped-down, receive-only flavor — see
`build.py --client`) don't show the address book, so there's no way to add
a deployed machine to it by hand. Instead, a client can self-register into
the address book on first launch, under a chosen group, using a small JSON
config dropped next to the installed app.

This lets you hand someone a single installer per site/customer and have
every machine it's installed on show up in the right group automatically —
no manual address-book entry per machine.

How it works, in short: on first launch the client looks for
`olidesk-deploy.json` next to its own executable. If found, it waits for
its RustDesk ID, then calls the address-book API's `/api/clients/register`
endpoint with that ID, its hostname (or the device name from the file, if
set), OS, and the group name from the file. Once registration succeeds it
remembers that (so it won't repeat on later launches) and deletes the JSON
file. See `flutter/lib/common/olidesk_deploy.dart` (client) and
`olidesk-api/app.py`'s `register_client` (server) for the implementation.

The Windows MSI writes that JSON file itself, from a device-name/group
prompt during setup (see "Installing with the MSI's built-in prompt"
below) — that's the normal path now. The rest of this doc, including
placing the file by hand, still applies to the portable EXE and to any MSI
built without the deployment secrets baked in.

## One-time server setup

1. `olidesk-api/config.json` holds the live admin and deploy tokens, so it's
   gitignored and never committed. On the server, create it once from the
   example (a `git pull` never touches it after that):
   ```
   cd olidesk-api
   cp config.json.example config.json
   ```
2. Fill in real values for `token` and `deploy_token` — two separate random
   strings.
   - `deploy_token` can only call `/api/clients/register`; it cannot read,
     list, or modify anything else in the address book, so it's safe to
     embed in deployment packages.
   - `token` is a **break-glass recovery credential, not a day-to-day admin
     token**. It can only call `/api/admin/devices` (list/add/revoke admin
     devices) — it cannot browse or edit the address book itself. Its only
     job is bootstrapping the first admin device on a fresh server, and
     recovering access if every device token is ever lost. Store it
     somewhere safe and separate from normal admin use (a password
     manager, not a chat message); see "Admin device authentication" below
     for how day-to-day access actually works.
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
- **Migrating an existing install**: if a device's saved token still shows
  as the old shared admin token, opening the address book tab now shows
  "This device is using an old shared admin token" with a **Register this
  device** button instead of the normal error screen — click it, name the
  device, and it swaps in a proper per-device token automatically. The old
  shared token itself keeps working as break-glass; nothing needs to be
  changed in `config.json`.
- **Audit log**: every admin auth attempt (address book calls and
  `/api/admin/devices` calls, success and failure alike) is appended to
  `olidesk-api/data/admin_auth.log` on the server, one line per attempt
  with a timestamp, source IP, device name (or `-` for a failed attempt),
  and endpoint.

## Installing with the MSI's built-in prompt (recommended)

The client MSI (`olidesk-client-*.msi`, built by `.github/workflows/client-build.yml`)
has `api_url` and `deploy_token` baked in at build time — see "Baking the
API URL and token into the MSI" below — and writes `olidesk-deploy.json`
itself during setup. There's no separate file to hand-place: download the
one MSI and install it anywhere.

**Interactive install**: after picking the install folder, a "Deployment
Configuration" screen appears with:
- **Device name** — pre-filled with the machine's hostname (`[ComputerName]`),
  editable.
- **Client group** — a dropdown fetched live from `GET /api/groups`. Pick an
  existing group, or just type a new name into the same box — typing a name
  that doesn't already exist creates it (same case-insensitive top-level
  match/create behavior as the JSON-based flow below). If the server can't
  be reached at install time, the dropdown has nothing in it but stays a
  normal editable field, and a hint explains why — the install never blocks
  on network access.

Finishing setup writes `olidesk-deploy.json` into the install folder from
whatever was entered, and first launch registers exactly like the manual
flow below (same retry-on-failure behavior, same log file).

**Silent install**: both fields are plain MSI properties, settable on the
command line —
```
msiexec /i olidesk-client-1.4.99-x86_64.msi GROUP="ASPEN GROUP" DEVICENAME="Reception PC" /qn
```
Omit `DEVICENAME` and it still defaults to the hostname; omit `GROUP` and
the client registers with no group. `/qn` skips all UI, including the
groups dropdown, but `olidesk-deploy.json` still gets written from whatever
properties were passed (or defaulted).

This only applies to the MSI. The portable/self-extracting EXE has no
installer UI to add a prompt to, and an admin-build MSI never gets one
either (`api_url`/`deploy_token` are only baked in for the client build) —
both use the manual approach below.

## Manual: placing olidesk-deploy.json by hand

For the portable EXE, an MSI built without deployment secrets baked in, or
any other case where the built-in prompt isn't available.

1. Get the client installer for the version you want to deploy — either
   download it from the GitHub release for that tag, or build it yourself
   with `build.py --client` (see `.github/workflows/client-build.yml` for
   the exact flags per platform).
2. Create `olidesk-deploy.json`:
   ```json
   {
     "api_url": "https://olidesk.olisys.co.il",
     "deploy_token": "<the deploy_token from config.json>",
     "group": "ASPEN GROUP",
     "device_name": "Reception PC"
   }
   ```
   `group` is matched case-insensitively against existing top-level groups
   and created automatically if it doesn't exist yet — no need to
   pre-create it in the address book. `device_name` is optional; the client
   falls back to its own hostname when it's absent. `/api/clients/register`
   is rate limited to 20 calls per hour per `deploy_token` (429 past that),
   and every accepted call is logged (IP, hostname, group, timestamp) in
   the `registration_events` table in the address-book database.
3. Put the installer and `olidesk-deploy.json` together (USB stick, network
   share, whatever's convenient). One JSON file per group/site — reuse the
   same installer for all of them.

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
  concern with the built-in prompt above, which writes the file itself
  after the install folder is created.)
- **Portable/self-extracting EXE**: copy `olidesk-deploy.json` into the
  same folder as the portable EXE *before* running it, so it's sitting next
  to it the first time it launches (wherever that folder is — USB stick,
  network share, etc.).

Then just launch Olidesk. Registration happens silently in the
background — no UI, nothing to click. If it can't reach the API yet (no
network on first boot, DNS not ready, etc.), it just retries on the next
launch instead of giving up.

## Baking the API URL and token into the MSI

`client-build.yml`'s "Build MSI" step passes `--api-url` and
`--deploy-token` to `res/msi/preprocess.py`, which only then defines the
WiX variables (`ApiUrl`/`DeployToken`) that
`res/msi/Package/UI/DeployConfigDlg.wxs` and the device-registration custom
actions (`res/msi/CustomActions/DeployConfig.cpp`) are gated behind via
`<?ifdef ApiUrl?>` — omit either flag (as the admin build's workflow does)
and the MSI compiles exactly as it did before this feature existed, no
prompt, no baked-in token.

The workflow reads the token from a **`OLIDESK_DEPLOY_TOKEN` repo secret**,
which needs to be added under Settings → Secrets and variables → Actions
before this works — its value should be the same `deploy_token` set in
`olidesk-api/config.json`. `api_url` isn't secret and is passed as a
literal in the workflow.

## Verifying / troubleshooting

Every run writes a plain-text log, timestamped line by line: file found or
not, config parsed or not, whether/when a RustDesk id showed up, the exact
HTTP request and response. Check it first — it's the fastest way to see
exactly where things stopped:

- Normally: `C:\Program Files\Olidesk\olidesk-deploy.log`, right next to
  the JSON file.
- If that folder isn't writable by the signed-in user (common for a
  non-admin user under `C:\Program Files`), it falls back to:
  `%APPDATA%\Olidesk\olidesk-deploy.log`, i.e.
  `C:\Users\<user>\AppData\Roaming\Olidesk\olidesk-deploy.log`.

Other things to check:

- Once registered, the client appears under the given group in the admin
  build's address book tab, `olidesk-deploy.json` is gone from the install
  folder, and the log's last line reads "registered successfully".
- A `olidesk-deploy.json` placed anywhere other than the installed app's
  own folder is invisible to the client — it just silently does nothing
  (there's no error for a missing file, by design, since most installs
  don't have one). This is the most common reason nothing happens: check
  the literal path above, not just "next to the installer".
- If a machine never shows up, check that `olidesk-deploy.json` has valid
  `api_url` and `deploy_token` values, that the machine can reach
  `api_url` over HTTPS, and read the log for the exact HTTP status/body the
  server returned.
- Re-registering an ID that's already in the address book updates its
  hostname/platform/group in place rather than creating a duplicate, so
  it's safe to reuse the same deploy package if you reinstall a machine.
