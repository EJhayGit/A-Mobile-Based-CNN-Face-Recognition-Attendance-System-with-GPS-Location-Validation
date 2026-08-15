# AGILA

AGILA is a research prototype for facial-recognition attendance in fleet and
driver operations. It combines an Android driver application, a Fleet Manager
web interface, a FastAPI service, and PostgreSQL/Supabase storage. Attendance
can be captured with face, liveness, and GPS checks while offline, queued on the
device, and synchronized when connectivity returns.

## Main features

- Driver activation, authentication, and assigned-delivery retrieval
- Local facial enrollment and 128-dimensional embedding comparison
- YuNet face detection and MediaPipe-based challenge-response liveness checks
- GPS validation against a manager-configured attendance radius
- Encrypted local attendance queue with idempotent synchronization
- Fleet Manager dashboard for drivers, deliveries, attendance, and audit events
- FastAPI authorization boundary backed by PostgreSQL/Supabase

## Architecture

The Flutter app performs camera capture, liveness, face inference, GPS checks,
and offline queuing on the Android device. When online, it authenticates to the
FastAPI API and synchronizes attendance records. FastAPI validates identity,
assignment, time, and geofence data before writing through SQLAlchemy to
PostgreSQL. The browser dashboard is served by the same backend and never
connects directly to the database.

## Technology stack

- Flutter/Dart and native Kotlin for Android
- ONNX Runtime Android, OpenCV YuNet, and MediaPipe Tasks Vision
- Python 3.11, FastAPI, SQLAlchemy, and psycopg
- PostgreSQL or Supabase PostgreSQL
- HTML, CSS, JavaScript, Leaflet, and OpenStreetMap
- Docker for backend/dashboard deployment

## Repository structure

```text
backend/             FastAPI API, authentication, persistence, and tests
dashboard/           Fleet Manager web interface
mobile_app/          Flutter Android application and tests
supabase/migrations/ PostgreSQL schema migrations
scripts/             Credential-free Windows demo launcher source
Dockerfile           Backend/dashboard container
```

## Prerequisites

- Python 3.11
- PostgreSQL 15+ or a Supabase PostgreSQL project
- Flutter SDK with Android tooling and Java 17
- Docker (optional)

## Backend and Fleet Manager setup

1. Create a virtual environment and install dependencies:

   ```powershell
   python -m venv backend/.venv
   backend/.venv/Scripts/python.exe -m pip install -r backend/requirements.txt
   ```

2. Copy `backend/.env.example` to the ignored `backend/.env`, replace every
   placeholder locally, and inject those variables into the process. The
   application intentionally does not load `.env` automatically.
3. Review and apply the migrations in `supabase/migrations/` to the intended
   empty development database.
4. Create the first Fleet Manager account and run the server:

   ```powershell
   backend/.venv/Scripts/python.exe -m backend.scripts.bootstrap_manager --login-id manager
   backend/.venv/Scripts/python.exe -m backend.server --host 127.0.0.1 --port 8080
   ```

5. Open `http://127.0.0.1:8080/login`. The API and Fleet Manager interface are
   served together.

Required environment-variable names are:

```text
DATABASE_URL
JWT_SECRET
ENVIRONMENT
COOKIE_SECURE
ALLOWED_HOSTS
CORS_ALLOWED_ORIGINS
BACKEND_HOST
PORT
ACCESS_TOKEN_MINUTES
REFRESH_TOKEN_HOURS
ACTIVATION_CODE_HOURS
ACTIVATION_MAX_ATTEMPTS
AUTH_RATE_LIMIT_ATTEMPTS
AUTH_RATE_LIMIT_WINDOW_SECONDS
ATTENDANCE_MAX_AGE_DAYS
ATTENDANCE_FUTURE_MINUTES
MAX_REQUEST_BYTES
ENABLE_API_DOCS
```

## Mobile setup

The biometric binaries are intentionally not distributed in this public
repository. Before building, place reviewed, legally redistributable/runtime
assets at the paths declared in `mobile_app/pubspec.yaml`:

```text
mobile_app/assets/models/final_face_embedding_fp32_opset18.onnx
mobile_app/assets/models/face_detection_yunet_2023mar.onnx
mobile_app/assets/models/face_landmarker.task
mobile_app/assets/diagnostics/yunet_validation.png
```

The final AGILA embedding weights and diagnostic image are private research
artifacts. YuNet and Face Landmarker assets must be obtained from their official
sources with the applicable license notices preserved.

Then run:

```powershell
cd mobile_app
flutter pub get
flutter test
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8080
```

Use an HTTPS API origin for release builds. Release signing requires a private,
ignored `mobile_app/android/key.properties` created from
`key.properties.example`; signing keys are never stored in this repository.

## Deployment

The Docker image serves FastAPI and the dashboard together. Supply environment
variables through the hosting platform and deploy with an explicit HTTPS host,
secure cookies, an allowlisted hostname, and an SSL PostgreSQL connection. A
typical build is `docker build -t agila .`; publish or run it only after adding
real secrets through the deployment platform, never the image or Git.

## Model and inference boundary

The Android client aligns a single YuNet-detected face to 224 x 224 RGB,
normalizes it, runs a compact MerLens V2 ONNX embedding model, and compares
unit-normalized embeddings with cosine similarity. Liveness is a separate
MediaPipe-assisted head-turn and color-response workflow. The server records
the device decision but does not independently rerun biometric inference.

## Limitations

AGILA is an Android-only thesis prototype, not a certified biometric or
anti-spoofing product. Liveness thresholds require broader device and lighting
calibration; formal participant usability and attack testing remain incomplete.
External face evaluation produced mixed results, so no universal accuracy or
security claim is made. GPS can also be affected by device conditions or
spoofing. Production use would require legal/privacy review, operational
monitoring, key management, signed releases, and additional field validation.
