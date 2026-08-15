"""Create the first Fleet Manager without exposing a password in source or logs."""

from __future__ import annotations

import argparse
import getpass

from backend.config import Settings
from backend.database import build_session_factory
from backend.services import AppError, bootstrap_manager


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--login-id", default="manager_test")
    args = parser.parse_args()
    password = getpass.getpass("Fleet Manager password: ")
    confirmation = getpass.getpass("Confirm password: ")
    if password != confirmation or len(password) < 10:
        raise SystemExit("Passwords must match and contain at least 10 characters.")
    settings = Settings.from_env()
    factory = build_session_factory(settings.database_url)
    try:
        with factory() as db:
            manager = bootstrap_manager(db, args.login_id, password)
    except AppError as error:
        raise SystemExit(error.message) from error
    print(f"Fleet Manager {manager.login_id} created.")


if __name__ == "__main__":
    main()
