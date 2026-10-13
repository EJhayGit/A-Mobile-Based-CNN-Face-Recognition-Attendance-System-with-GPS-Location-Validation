# AGILA — CNN-Based Facial Recognition Attendance System with GPS Authentication

AGILA is an undergraduate Computer Science thesis prototype for construction
field-personnel attendance. It combines an Android application, a Fleet Manager
web application, a FastAPI backend, and PostgreSQL/Supabase storage. Facial
verification, pose-based liveness, and GPS checks run on the phone; accepted
attendance is encrypted locally and synchronized when connectivity returns.

The official thesis title is **Cross-Platform CNN-Based Mobile Facial Recognition
Attendance System with GPS Authentication**. The implemented mobile client is
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

## Docker

The existing Dockerfile builds only the backend and Fleet Manager web app. It
uses Python 3.11, installs pinned backend requirements, serves the dashboard from
the same origin, runs as an unprivileged user, exposes port 8080, and probes
`/health`. Credentials are supplied at runtime.

After configuring the database and `backend/.env` above, local HTTP testing:

```powershell
docker build -t agila .
docker run --rm --name agila -p 127.0.0.1:8080:8080 --env-file backend/.env -e BACKEND_HOST=0.0.0.0 -e ENVIRONMENT=development -e COOKIE_SECURE=false -e ALLOWED_HOSTS=localhost,127.0.0.1 agila
```

Use a database hostname reachable **from the container**; host-machine
`localhost` refers to the container itself. On Docker Desktop,
`host.docker.internal` can address a host database. Visit `/login` and `/health`
at the local address above. Bootstrap a manager with the same configured
environment using `docker exec -it agila python -m backend.scripts.bootstrap_manager --login-id manager`.

For hosting, use an HTTPS reverse proxy, `ENVIRONMENT=production`,
`COOKIE_SECURE=true`, explicit `ALLOWED_HOSTS`, and a PostgreSQL connection with
`sslmode=require`. Keep secrets in the hosting platform. No production deployment
is performed by this release update. Docker configuration was statically reviewed;
a container build/smoke test could not run because the local Docker engine was
unavailable.

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
at `0.2071264386`. The historical fixed-threshold LFW evaluation reported 73.10%
accuracy, 35.20% FAR, and 18.60% FRR. These results do not validate runtime `0.35`,
constitute on-device accuracy, or establish presentation-attack resistance.
Participant studies and later engineering changes are separate evidence; this
release does not publish participant records or claim production readiness.
See [model development](docs/model-development.md),
[export](docs/model-export.md), and [model card](docs/model-card.md).

DigiFace-1M's [R-UDA](https://github.com/microsoft/DigiFace1M/blob/main/LICENSE)
defines trained models as Results and prohibits commercial use of Data or
Results. The retained model is intended for non-commercial academic research;
no broader software license or third-party redistribution permission is implied.
Dataset images, checkpoints, embeddings, and experiment outputs are excluded.

## Thesis manuscript

The final manuscript has not yet been supplied for public release. No draft or
older manuscript is included; publication will wait for the authors' final file.

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
