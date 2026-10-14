# AGILA — A Mobile-Based CNN Face Recognition Attendance System with GPS Location Validation

AGILA is an undergraduate Computer Science thesis prototype for construction
field-personnel attendance. It combines an Android application, a Fleet Manager
web application, a FastAPI backend, and PostgreSQL/Supabase storage. Facial
verification, pose-based liveness, and GPS checks run on the phone; accepted
attendance is encrypted locally and synchronized when connectivity returns.

The official thesis title is **A Mobile-Based CNN Face Recognition Attendance System with GPS Location Validation**. The implemented mobile client is
Android-only. This public release contains selected application and model source;
it does not contain the private thesis workspace or its development history.

## Features

- Field Personnel activation, sign-in, deactivation, and history-preserving deletion
- Site Locations with configurable GPS radii and ordered multi-stop Site Assignments
- Latest Site Assignment, per-site progress, offline attendance, and idempotent sync
- Fleet Manager personnel, assignment, location, attendance, and audit management
- Manager-approved face re-registration with atomic local template replacement
- One authorized app installation per account, signed device proofs, and
  manager-reviewed device replacement
- Paginated web records, responsive navigation, and updated attendance messages

Device authorization is a later engineering correction. Automated tests cover
it; physical two-phone verification is still required. Development biometric
testing tools are gated out of release builds. User-facing terminology uses
Field Personnel and Site Assignments; existing Driver/delivery identifiers are
retained internally for compatibility.

## Architecture and technology

```text
Android (Flutter/Dart + Kotlin)
  camera → YuNet alignment → MerLens embedding → pose/GPS checks → encrypted queue
                               │ authenticated HTTPS + device proofs
                               ▼
Fleet Manager browser ← FastAPI (Python/SQLAlchemy) → PostgreSQL/Supabase
```

The browser is served by FastAPI and never connects directly to the database.
Facial templates and images are not uploaded. The server enforces account,
device, assignment, timing, and geofence rules; it does not rerun face inference.

The stack uses Flutter, ONNX Runtime Android, OpenCV YuNet, MediaPipe Face
Landmarker, FastAPI/Uvicorn, SQLAlchemy/psycopg, PostgreSQL, and HTML/CSS/JavaScript
with Leaflet/OpenStreetMap. Montserrat's font notice is in
[docs/licenses/Montserrat-OFL.txt](docs/licenses/Montserrat-OFL.txt).

## Repository structure

| Path | Contents |
| --- | --- |
| `backend/` | API, security, persistence, configuration template, and tests |
| `dashboard/` | Fleet Manager web application and AGILA branding |
| `mobile_app/` | Android application, native bridges, and tests |
| `supabase/migrations/` | Ordered database setup and feature migrations |
| `ai/` | MerLens architecture, preprocessing, curriculum, evaluation, export, and tests |
| `docs/` | Public model documentation, database setup, and asset notices |
| `Dockerfile` | Backend and dashboard container |

## Prerequisites

- Python 3.11+ compatible with the pinned backend dependencies
- A dedicated empty development PostgreSQL/Supabase database
- Flutter/Dart satisfying `mobile_app/pubspec.yaml` (Dart `^3.12.2`), Android
  tooling, Java 17, and Android API 24+ on the device
- Docker Engine for container use

## Database and backend setup

1. Read [database setup](docs/database-setup.md). Review the migrations in
   filename order before applying them to an **empty disposable development
   database**. The historical chain contains a destructive application-schema
   reset; never apply the full chain to an existing or production database.
2. Provision a separate PostgreSQL login with membership in `fleet_backend`.
   Application queries must not run as the database administrator.
3. Create a backend environment and configuration file:

   ```powershell
   python -m venv .venv
   .venv/Scripts/python.exe -m pip install -r backend/requirements-dev.txt
   Copy-Item backend/.env.example backend/.env
   ```

4. Replace the database and JWT placeholders in the ignored `backend/.env`.
   For local HTTP, use `ENVIRONMENT=development`, `COOKIE_SECURE=false`,
   `ALLOWED_HOSTS=localhost,127.0.0.1`, and `BACKEND_HOST=127.0.0.1`.
   The application does **not** load `.env` automatically. Inject its values
   into your shell using your environment manager before starting Python.
5. Bootstrap the first manager (the command prompts for the password), then run:

   ```powershell
   .venv/Scripts/python.exe -m backend.scripts.bootstrap_manager --login-id manager
   .venv/Scripts/python.exe -m backend.server --host 127.0.0.1 --port 8080
   ```

Open `http://127.0.0.1:8080/login`. `/health` is the lightweight reachability
endpoint. Later devices for existing accounts need manager authorization; a
fresh activation can authorize the first installation.

## Docker Installation

Download the public [AGILA container package](https://github.com/users/EJhayGit/packages/container/package/a-mobile-based-cnn-face-recognition-attendance-system-with-gps-location-validation). Version `1.0.1`
contains the FastAPI backend, Fleet Manager website, and production dependencies
for **Linux AMD64**. Docker Desktop must use Linux containers. No login to GitHub
is required to pull it; the Flutter application is separate.

```powershell
docker pull ghcr.io/ejhaygit/a-mobile-based-cnn-face-recognition-attendance-system-with-gps-location-validation:1.0.1
```

1. Configure PostgreSQL/Supabase **separately** following
   [database setup](docs/database-setup.md). The image contains no database,
   migrations to execute automatically, private credentials, or participant
   records. Configure the application schema and a least-privilege login before
   using account/attendance features. Never run the full reset chain on existing
   data.
2. Copy `backend/.env.example` from this repository to your ignored
   `backend/.env`. Set your own `DATABASE_URL` and `JWT_SECRET` (at least 32
   random bytes). Use a database hostname reachable from the container;
   `localhost` inside it refers to the container. On Docker Desktop,
   `host.docker.internal` can address a host database. Keep this file private.
3. For local HTTP use, start the downloaded image:

   ```powershell
   docker run -d --name agila -p 127.0.0.1:8080:8080 --env-file backend/.env -e BACKEND_HOST=0.0.0.0 -e PORT=8080 -e ENVIRONMENT=development -e COOKIE_SECURE=false -e ALLOWED_HOSTS=localhost,127.0.0.1 ghcr.io/ejhaygit/a-mobile-based-cnn-face-recognition-attendance-system-with-gps-location-validation:1.0.1
   ```

4. If the separately configured database has no manager, bootstrap one; the
   command prompts privately for the password:

   ```powershell
   docker exec -it agila python -m backend.scripts.bootstrap_manager --login-id manager
   ```

5. Open the Fleet Manager website at `http://127.0.0.1:8080/login`. Verify the
   backend with `http://127.0.0.1:8080/health`, which should return
   `{"status":"ok"}`. This health check performs a database `SELECT 1`; it
   confirms connectivity, not schema completeness or biometric accuracy.

   ```powershell
   curl.exe --fail http://127.0.0.1:8080/health
   docker ps --filter name=agila
   docker logs agila
   ```

Required configuration names are `DATABASE_URL`, `JWT_SECRET`, `ALLOWED_HOSTS`,
`ENVIRONMENT`, and `COOKIE_SECURE`. The image defaults to `BACKEND_HOST=0.0.0.0`,
`PORT=8080`, `ENVIRONMENT=production`, and `COOKIE_SECURE=true`; the local command
above deliberately supplies development settings. The complete optional
configuration is in [backend/.env.example](backend/.env.example) and the
Environment variables section below. No runtime environment file or secret is
embedded in the image. Remove a stopped local container before reusing its name.

For hosting, configure your own HTTPS reverse proxy, explicit `ALLOWED_HOSTS`,
`ENVIRONMENT=production`, `COOKIE_SECURE=true`, and a `DATABASE_URL` including
`sslmode=require`. Keep credentials in runtime configuration. The image does
not change or deploy the existing Render service.

The unchanged [Dockerfile](Dockerfile) remains available for source builds:
`docker build --platform linux/amd64 -t agila .`. The published image runs as
the unprivileged `agila` user and exposes container port 8080.

### Verified release

On 2026-10-14, version `1.0.1` built from public source commit
`e0e9fa16b4e56026893333301dcbf9104109e880` passed production-mode startup,
SSL PostgreSQL `/health`, `/login`, `/assets/app.js`, `/assets/styles.css`,
and the Dockerfile healthcheck using disposable local containers. No project
migrations or existing database operations were performed. Image inspection
found no private credentials, runtime `.env`, Git history, Flutter source,
model/training artifacts, or participant records. An anonymous pull using an
empty Docker credential configuration and both public web links passed.
Registry digest: `sha256:58f7d929648c80cbc515d85817a769940a0e675fa068e73b78032cfd9486f180`.

The [printable Appendix P](docs/thesis/GITHUB-DOCKER-LINKS.pdf) contains the
verified links and pull command; see its
[source and insertion note](docs/thesis/GITHUB-DOCKER-LINKS.md).

## Android setup

The existing final inference-only MerLens ONNX is retained in
`mobile_app/assets/models/`. Independently obtain the remaining runtime assets
from their official sources, verify them, and preserve the applicable notices:

- `face_detection_yunet_2023mar.onnx` — [OpenCV Zoo YuNet](https://github.com/opencv/opencv_zoo/tree/4.10.0/models/face_detection_yunet)
- `face_landmarker.task` — [MediaPipe Face Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker)

See the [runtime asset guide](mobile_app/assets/models/README.md). A diagnostic
face image is no longer required. Then:

```powershell
cd mobile_app
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=API_BASE_URL=https://YOUR-BACKEND-HOST
```

For local debug HTTP, point to an address reachable from the phone/emulator and
allow that backend hostname. Release builds require HTTPS. Create your own
ignored signing configuration from `android/key.properties.example`; signing
keys, passwords, APKs, and build caches are excluded from Git. This repository
does not supply a signed APK or claim that a fresh device installation was tested.

## Environment variables

[backend/.env.example](backend/.env.example) is the complete placeholder template.
Required secrets: `DATABASE_URL` and `JWT_SECRET` (at least 32 random bytes).

Runtime configuration: `ENVIRONMENT`, `COOKIE_SECURE`, `ALLOWED_HOSTS`,
`CORS_ALLOWED_ORIGINS`, `BACKEND_HOST`, `PORT`, `ACCESS_TOKEN_MINUTES`,
`REFRESH_TOKEN_HOURS`, `ACTIVATION_CODE_HOURS`, `ACTIVATION_MAX_ATTEMPTS`,
`AUTH_RATE_LIMIT_ATTEMPTS`, `AUTH_RATE_LIMIT_WINDOW_SECONDS`,
`ATTENDANCE_MAX_AGE_DAYS`, `ATTENDANCE_FUTURE_MINUTES`, `MAX_REQUEST_BYTES`,
and `ENABLE_API_DOCS`. Mobile `API_BASE_URL` is a Dart build-time value.

## Model and research boundary

MerLens V2 is a project-authored CNN trained from random initialization, producing
128-dimensional normalized embeddings from aligned 224 × 224 RGB faces. YuNet
is the separate pretrained detector; MediaPipe supplies pose signals. Current
application cosine threshold is provisional `0.35`; all three individual scores
and the aggregate must satisfy the production verification rule. Active liveness
uses head turns and centered return; the unreliable color-response gate was removed.

Historical internal synthetic validation reported 98.42% accuracy and 1.58% EER
at `0.2071264386`. The original locked-threshold LFW evaluation reported 73.10%
accuracy, 35.20% FAR, and 18.60% FRR. The updated thesis also reports the following
later model-level evaluations at the already chosen provisional `0.35`:

| Evaluation | Accuracy | FAR | FRR | Balanced error |
| --- | ---: | ---: | ---: | ---: |
| Post-hoc LFW View 2 | 77.17% | 8.43% | 37.23% | 22.83% |
| No-tuning AgeDB-30 | 51.28% | 16.27% | 81.17% | 48.72% |

Each uses 6,000 official pairs, retaining processing failures in the denominator.
These are single-pair model decisions, not the app's three-template/aggregate,
liveness, GPS, or complete attendance workflow. They were not rerun for this
release; `0.35` remains provisional and the synthetic-to-real limitation remains.
The thesis reports 120 of 132 completed attendance attempts (90.9% workflow
completion, not biometric accuracy), mean SUS 57.5 in each small personnel and
manager group, and all 10 records synchronized after one controlled 15-minute
outage. These descriptive study findings do not establish production readiness.
GPS checks provide location validation; formal GPS-spoof and presentation-attack
testing was not performed. No raw participant source records are published.
The later device-authorization correction is separate engineering evidence.
See [model development](docs/model-development.md),
[export](docs/model-export.md), and [model card](docs/model-card.md).

DigiFace-1M's [R-UDA](https://github.com/microsoft/DigiFace1M/blob/main/LICENSE)
defines trained models as Results and prohibits commercial use of Data or
Results. The retained model is intended for non-commercial academic research;
no broader software license or third-party redistribution permission is implied.
Dataset images, checkpoints, embeddings, and experiment outputs are excluded.

## Thesis manuscript

Read the [updated thesis public edition](docs/thesis/AGILA-Thesis-Public-Edition.pdf)
and its [publication and privacy note](docs/thesis/README.md). The 153-page public
copy omits sensitive appendix pages and corrects unrelated PDF title metadata.
Retained manuscript content, original printed pagination, and historical
appendix snapshots are unchanged. The original supplied PDF is not included.

## Verification

```powershell
.venv/Scripts/python.exe -m pytest backend/tests -q
.venv/Scripts/python.exe -m ruff check backend
node --check dashboard/app.js
cd mobile_app
flutter analyze
flutter test
```

Backend tests use synthetic accounts and disposable SQLite fixtures; runtime
configuration requires PostgreSQL. No training, expensive biometric evaluation,
participant collection, production database operation, or deployment is required
for these checks.
