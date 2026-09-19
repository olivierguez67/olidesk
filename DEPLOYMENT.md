# Client deployment (auto-registration)

Olidesk client builds (the stripped-down, receive-only flavor — see
`build.py --client`) don't show the address book, so there's no way to add
a deployed machine to it by hand. Instead, a client can self-register into
the address book on first launch, under a chosen group, using a small JSON
config dropped next to the installed app.

This lets you build one deployment package per site/customer — client
installer + a JSON file naming their group — and have every machine you
install it on show up in the right place automatically.

How it works, in short: on first launch the client looks for
`olidesk-deploy.json` next to its own executable. If found, it waits for
its RustDesk ID, then calls the address-book API's `/api/clients/register`
endpoint with that ID, its hostname, OS, and the group name from the file.
Once registration succeeds it remembers that (so it won't repeat on later
launches) and deletes the JSON file. See
`flutter/lib/common/olidesk_deploy.dart` (client) and
`olidesk-api/app.py`'s `register_client` (server) for the implementation.

## One-time server setup

1. Set a `deploy_token` in `olidesk-api/config.json` — a random string,
   separate from the admin `token`. This token can only call
   `/api/clients/register`; it cannot read, list, or modify anything else
   in the address book, so it's safe to embed in deployment packages.
2. Restart the API container so it picks up the new config:
   ```
   docker compose restart olidesk-api
   ```

## Building a deploy package

1. Get the client installer for the version you want to deploy — either
   download it from the GitHub release for that tag (`olidesk-client-*.msi`
   or `olidesk-client-*.exe`), or build it yourself with
   `build.py --client` (see `.github/workflows/client-build.yml` for the
   exact flags per platform).
2. Create `olidesk-deploy.json`:
   ```json
   {
     "api_url": "https://olidesk.olisys.co.il",
     "deploy_token": "<the deploy_token from config.json>",
     "group": "ASPEN GROUP"
   }
   ```
   `group` is matched case-insensitively against existing top-level groups
   and created automatically if it doesn't exist yet — no need to
   pre-create it in the address book.
3. Put the installer and `olidesk-deploy.json` together (USB stick, network
   share, whatever's convenient). One JSON file per group/site — reuse the
   same installer for all of them.

## Installing on a machine

Where `olidesk-deploy.json` needs to end up depends on which installer
you're using, because the client reads it from the same folder as its own
running executable:

- **MSI install**: run the installer normally (installs to
  `C:\Program Files\Olidesk\` by default), then copy
  `olidesk-deploy.json` into that same install folder, next to
  `olidesk.exe`.
- **Portable/self-extracting EXE**: copy `olidesk-deploy.json` into the
  same folder as the portable EXE *before* running it, so it's sitting next
  to it the first time it launches.

Then just launch Olidesk. Registration happens silently in the
background — no UI, nothing to click. If it can't reach the API yet (no
network on first boot, DNS not ready, etc.), it just retries on the next
launch instead of giving up.

## Verifying / troubleshooting

- Once registered, the client appears under the given group in the admin
  build's address book tab, and `olidesk-deploy.json` is gone from the
  install folder.
- If a machine never shows up, check that `olidesk-deploy.json` has valid
  `api_url` and `deploy_token` values, that the machine can reach
  `api_url` over HTTPS, and check the client's debug log for lines starting
  with `olidesk auto-registration`.
- Re-registering an ID that's already in the address book updates its
  hostname/platform/group in place rather than creating a duplicate, so
  it's safe to reuse the same deploy package if you reinstall a machine.
