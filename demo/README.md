# AGILA demonstration on the dean's PC

This setup runs Fleet Manager, FastAPI and a separate PostgreSQL demo database
on the PC. It uses the published server image and existing migrations. No
Python, Flutter, PostgreSQL installation, Supabase account or manually written
environment file is needed on the dean's PC. It does not connect to the hosted
system or copy its users, credentials or attendance records.

## Prepare before the presentation

1. Use a Windows x64 PC that meets the current
   [Docker Desktop requirements](https://docs.docker.com/desktop/setup/install/windows-install/).
   Install Docker Desktop from that official page, enable its Linux/WSL 2
   engine, and complete any installer/restart/first-launch steps yourself.
   School IT may need to enable virtualization or WSL. Do this before demo day.
2. Download the entire [public repository](https://github.com/EJhayGit/A-Mobile-Based-CNN-Face-Recognition-Attendance-System-with-GPS-Location-Validation)
   using **Code > Download ZIP**, and extract it completely into a writable
   folder. Alternatively clone it with Git. Keep `demo/` and
   `supabase/migrations/` beside the launchers; do not run inside the ZIP.
3. Double-click **Start-Demo.cmd** in the extracted repository root. Internet
   is needed for the first image downloads; allow time for those downloads.
4. Wait for **Ready**. The launcher opens Fleet Manager and a private Notepad
   note with the generated initial manager login. Sign in and rehearse using
   disposable demo accounts.
5. Double-click **Stop-Demo.cmd** when finished. It preserves the demo data.

Only Docker is needed on the host. The `.cmd` launchers do not change PowerShell
execution policy, firewall rules, Windows services or BIOS settings. Installers
and school policies still require the user's/IT's normal approval.

## What Start does automatically

- Checks for Docker's Linux engine and Compose, attempting to start Docker
  Desktop if the engine is stopped.
- Creates random, local-only database passwords, JWT secret and manager
  credentials in the ignored `demo/local/` folder.
- Starts the separately named `agila-dean-demo` Compose project. PostgreSQL is
  reachable only by its containers; it publishes no database port on Windows.
- Initializes an empty demo database using the eight exact approved migration
  files and a restricted application login. It creates the initial manager.
- Waits for database-backed server health before opening `/login`.

The default website is `http://127.0.0.1:8080/login`; health is
`http://127.0.0.1:8080/health`. The manager note is
`demo/local/manager-login.txt`. Keep the whole local folder private. The note
contains the initial password; changing the password in the app does not update
it. Credentials are never included in the public source or container image.

If port 8080 is occupied, open a command prompt in the repository folder and run:

```bat
Start-Demo.cmd --port 8081
```

Restarts preserve accounts, locations, assignments, records and passwords.
Network/port choices also persist. The database lives in a dedicated Docker
volume; the matching private instance/credentials live in `demo/local/`. Keep
both. Copying the repository folder alone does not copy the database volume.
The launcher refuses an unknown schema, different instance or changed migration
bundle instead of resetting data. There is deliberately no automatic reset or
volume-deletion command. Stop does not affect unrelated containers.

## Connect an Android phone

The PC launcher supplies the server and website. The mobile app still runs on
an Android device. The **release APK requires HTTPS** and cannot connect to this
local HTTP server. Use a prepared debug build on a dedicated test phone for this
LAN demonstration. The launcher does not build or install an APK.

1. Connect PC and phone to the same trusted network or a rehearsed phone hotspot.
   Find the PC's Wi-Fi/Ethernet IPv4 address with `ipconfig`.
2. Start with that specific private address, for example:

   ```bat
   Start-Demo.cmd --host 192.168.1.23
   ```

   Replace the example with the PC's actual address. This updates both Docker's
   published interface and the backend's allowed host. Public/unspecified
   addresses are refused. Return to PC-only access with
   `Start-Demo.cmd --host 127.0.0.1`.
3. On the phone, open `http://192.168.1.23:8080/health` in a browser first. If
   it fails, check the address, school Wi-Fi client isolation and a scoped
   private-network firewall permission with school IT. The launcher does not
   change firewall policy. Do not use the phone's `localhost` for the PC.
4. On your own development computer, follow the root Android setup, including
   the verified runtime assets, and prepare a debug APK for that address:

   ```powershell
   cd mobile_app
   flutter build apk --debug --dart-define=API_BASE_URL=http://192.168.1.23:8080
   ```

   The output is `mobile_app/build/app/outputs/flutter-apk/app-debug.apk` from
   the repository root. Prepare/install it before the presentation; no Flutter
   tooling is needed on the dean's PC. Use the correct backend address in the
   app's server setup. A debug APK cannot update a differently signed release
   APK; use a dedicated test device and do not remove an installation containing
   unsynchronized records just to install this build.
5. Create and activate a demo Field Personnel account through this local Fleet
   Manager. A fresh local database has no old account/device authorizations.
   Rehearse camera/location permissions, enrollment, manager-controlled device
   authorization and site-radius checks on the actual phone.

Do not use the historical hosted API default for this local demonstration.
LAN HTTP and the demo credentials are for a controlled demonstration, not a
production deployment. The application, biometric rules and release HTTPS
requirements are unchanged.

## Rehearse the full flow

1. Start, sign in as the generated manager and create demo site/personnel data.
2. Activate/enroll on the test phone, assign a site route and perform check-in.
3. Show the offline queue by disconnecting the phone from the server, then
   reconnect and verify synchronization in the local Fleet Manager.
4. Stop, start again and verify that the demo records are still present.
5. Keep a browser-only manager walkthrough ready if the room's network prevents
   phone-to-PC traffic. Physical camera/GPS/liveness and room-network behavior
   require rehearsal; server checks do not certify those device functions.

## If startup fails

- **Docker missing/stopped/Windows-container mode:** open Docker Desktop and
  select its Linux engine. Finish installation/WSL/reboot steps before retrying.
- **Docker Desktop crashes before the engine starts:** this is a Docker host
  problem. Keep images/volumes and gather diagnostics; do not use a factory
  reset as a routine setup step. See [Docker troubleshooting](https://docs.docker.com/desktop/troubleshoot/overview/).
- **Downloads fail:** check internet access to GHCR/Docker Hub and try again.
  Keep the downloaded images cached on the demo PC after a successful rehearsal.
- **Port already used:** choose another port with `--port`; do not stop an
  unrelated application. Include that new port in the phone URL too.
- **Configuration/schema mismatch:** keep `demo/local/` and the Docker volume.
  Restore the matching private folder/repository version; do not delete the
  folder or rerun reset SQL against a database containing demo records.
- **Login fails after a password change:** use the changed password; the note
  is initial-login information, not a password reset tool.

For setup logs, run from the root and keep output private:

```bat
docker compose --project-name agila-dean-demo --env-file demo/local/.env --file demo/compose.yaml logs --tail 30 setup
```

For automated/headless checks, `--no-open --no-pause` suppresses the Notepad,
browser and final pause; normal double-click use needs no flags.
