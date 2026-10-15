"""Create private credentials for the local Fleet Manager demonstration."""

from __future__ import annotations

import argparse
import ipaddress
import os
import secrets
import sys
import tempfile
from pathlib import Path

KEYS = (
    "DEMO_INSTANCE_ID",
    "DEMO_DB_ADMIN_PASSWORD",
    "DEMO_DB_APP_PASSWORD",
    "DEMO_JWT_SECRET",
    "DEMO_MANAGER_PASSWORD",
    "DEMO_MANAGER_LOGIN",
    "DEMO_BIND_ADDRESS",
    "DEMO_HTTP_PORT",
)


def _validate_bind(address: str) -> str:
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError as error:
        raise ValueError(
            "bind address must be a loopback or private IPv4 address"
        ) from error
    rfc1918 = (
        any(
            parsed in ipaddress.ip_network(network)
            for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
        )
        if parsed.version == 4
        else False
    )
    if parsed.version != 4 or not (parsed.is_loopback or rfc1918):
        raise ValueError("bind address must be a loopback or private IPv4 address")
    return str(parsed)


def _validate_port(value: int | str) -> str:
    try:
        port = int(value)
    except (TypeError, ValueError) as error:
        raise ValueError("port must be an integer from 1024 through 65535") from error
    if str(value).strip() != str(port) or not 1024 <= port <= 65535:
        raise ValueError("port must be an integer from 1024 through 65535")
    return str(port)


def _parse_env(data: bytes) -> dict[str, str]:
    try:
        lines = data.decode("ascii").splitlines()
        values: dict[str, str] = {}
        for line in lines:
            if not line or "=" not in line:
                raise ValueError
            key, value = line.split("=", 1)
            if key in values or key not in KEYS or not value:
                raise ValueError
            values[key] = value
        if set(values) != set(KEYS):
            raise ValueError
        if len(values["DEMO_INSTANCE_ID"]) != 32 or any(
            c not in "0123456789abcdef" for c in values["DEMO_INSTANCE_ID"]
        ):
            raise ValueError
        for key, length in (
            ("DEMO_DB_ADMIN_PASSWORD", 64),
            ("DEMO_DB_APP_PASSWORD", 64),
            ("DEMO_JWT_SECRET", 96),
            ("DEMO_MANAGER_PASSWORD", 40),
        ):
            if len(values[key]) != length or any(
                c not in "0123456789abcdef" for c in values[key]
            ):
                raise ValueError
        if values["DEMO_MANAGER_LOGIN"] != "demo_manager":
            raise ValueError
        _validate_bind(values["DEMO_BIND_ADDRESS"])
        values["DEMO_HTTP_PORT"] = _validate_port(values["DEMO_HTTP_PORT"])
        return values
    except (UnicodeError, ValueError) as error:
        raise ValueError(
            "existing demo configuration is malformed; refusing to replace it"
        ) from error


def _atomic_create(path: Path, data: bytes) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=path.parent, prefix=".demo-", delete=False
        ) as temp:
            temp_name = temp.name
            temp.write(data)
            temp.flush()
            os.fsync(temp.fileno())
        try:
            os.chmod(temp_name, 0o600)
        except OSError:
            pass
        try:
            os.link(temp_name, path)
            return True
        except FileExistsError:
            return False
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass


def _replace(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=path.parent, prefix=".demo-", delete=False
    ) as temp:
        temp_name = temp.name
        temp.write(data)
        temp.flush()
        os.fsync(temp.fileno())
    try:
        try:
            os.chmod(temp_name, 0o600)
        except OSError:
            pass
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def _env_bytes(values: dict[str, str]) -> bytes:
    return ("".join(f"{key}={values[key]}\n" for key in KEYS)).encode("ascii")


def _login_note(values: dict[str, str]) -> bytes:
    url = f"http://{values['DEMO_BIND_ADDRESS']}:{values['DEMO_HTTP_PORT']}"
    return f"AGILA local demo - keep this file private\n\nUsername: {values['DEMO_MANAGER_LOGIN']}\nInitial password: {values['DEMO_MANAGER_PASSWORD']}\nWebsite: {url}/login\n\nChanging the password in the app does not update this initial note.\n".encode(
        "ascii"
    )


def create_configuration(
    directory: Path | str,
    bind_address: str | None = None,
    port: int | str | None = None,
) -> dict[str, str]:
    directory = Path(directory)
    env_path = directory / ".env"
    requested_bind = _validate_bind(bind_address) if bind_address is not None else None
    requested_port = _validate_port(port) if port is not None else None
    try:
        data = env_path.read_bytes()
    except FileNotFoundError:
        values = {
            "DEMO_INSTANCE_ID": secrets.token_hex(16),
            "DEMO_DB_ADMIN_PASSWORD": secrets.token_hex(32),
            "DEMO_DB_APP_PASSWORD": secrets.token_hex(32),
            "DEMO_JWT_SECRET": secrets.token_hex(48),
            "DEMO_MANAGER_PASSWORD": secrets.token_hex(20),
            "DEMO_MANAGER_LOGIN": "demo_manager",
            "DEMO_BIND_ADDRESS": requested_bind or "127.0.0.1",
            "DEMO_HTTP_PORT": requested_port or "8080",
        }
        _atomic_create(env_path, _env_bytes(values))
        # Re-read the winner if another process created the file concurrently.
        values = _parse_env(env_path.read_bytes())
    else:
        values = _parse_env(data)
        changed = False
        if requested_bind is not None and requested_bind != values["DEMO_BIND_ADDRESS"]:
            values["DEMO_BIND_ADDRESS"] = requested_bind
            changed = True
        if requested_port is not None and requested_port != values["DEMO_HTTP_PORT"]:
            values["DEMO_HTTP_PORT"] = requested_port
            changed = True
        if changed:
            _replace(env_path, _env_bytes(values))
    note_path = directory / "manager-login.txt"
    if not note_path.exists():
        _atomic_create(note_path, _login_note(values))
    elif requested_bind is not None or requested_port is not None:
        _replace(note_path, _login_note(values))
    return values


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", default="/demo/local")
    parser.add_argument("--bind-address")
    parser.add_argument("--port")
    args = parser.parse_args()
    bind = (
        args.bind_address
        if args.bind_address is not None
        else (os.getenv("DEMO_REQUESTED_BIND_ADDRESS") or None)
    )
    port = (
        args.port
        if args.port is not None
        else (os.getenv("DEMO_REQUESTED_PORT") or None)
    )
    try:
        values = create_configuration(args.directory, bind, port)
    except (OSError, ValueError):
        print(
            "Demo configuration failed; check the requested address, port, and writable directory.",
            file=sys.stderr,
        )
        return 1
    print(
        f"Demo credentials ready. Open http://{values['DEMO_BIND_ADDRESS']}:{values['DEMO_HTTP_PORT']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
