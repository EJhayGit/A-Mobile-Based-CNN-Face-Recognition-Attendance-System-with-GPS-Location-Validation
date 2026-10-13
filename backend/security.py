"""Password, activation-code, token, and session security primitives."""

from __future__ import annotations

import base64
import binascii
import hashlib
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from backend.config import Settings

password_hasher = PasswordHasher()
DUMMY_SECRET_HASH = password_hasher.hash("constant-dummy-value-for-timing-equalization")
ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def hash_secret(value: str) -> str:
    return password_hasher.hash(value)


def verify_secret(stored_hash: str | None, candidate: str) -> bool:
    if not stored_hash:
        return False
    try:
        return password_hasher.verify(stored_hash, candidate)
    except (VerificationError, InvalidHashError):
        return False


def generate_activation_code() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(8))


def generate_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def refresh_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def generate_csrf_token() -> str:
    return secrets.token_urlsafe(32)


def create_access_token(
    account_id: str, role: str, session_id: str, settings: Settings
) -> tuple[str, int]:
    now = datetime.now(timezone.utc)
    expires = now + timedelta(minutes=settings.access_minutes)
    token = jwt.encode(
        {
            "sub": account_id,
            "role": role,
            "sid": session_id,
            "iat": now,
            "exp": expires,
            "type": "access",
        },
        settings.jwt_secret,
        algorithm="HS256",
    )
    return token, int((expires - now).total_seconds())


def decode_access_token(token: str, settings: Settings) -> dict[str, object]:
    payload = jwt.decode(token, settings.jwt_secret, algorithms=["HS256"])
    if payload.get("type") != "access":
        raise jwt.InvalidTokenError("Unexpected token type")
    return payload


def create_device_challenge(login_id: str, purpose: str, settings: Settings) -> str:
    now = datetime.now(timezone.utc)
    return jwt.encode(
        {
            "sub": login_id.strip().upper(),
            "purpose": purpose,
            "nonce": secrets.token_urlsafe(32),
            "iat": now,
            "exp": now + timedelta(minutes=2),
            "type": "device_challenge",
        },
        settings.jwt_secret,
        algorithm="HS256",
    )


def verify_device_proof(
    *,
    login_id: str,
    purpose: str,
    public_key: str,
    challenge: str,
    signature: str,
    settings: Settings,
) -> tuple[str, str]:
    try:
        payload = jwt.decode(challenge, settings.jwt_secret, algorithms=["HS256"])
    except jwt.PyJWTError as error:
        raise ValueError("Invalid device proof") from error
    if (
        payload.get("type") != "device_challenge"
        or payload.get("sub") != login_id.strip().upper()
        or payload.get("purpose") != purpose
    ):
        raise ValueError("Invalid device proof")
    try:
        key_bytes = base64.b64decode(public_key, validate=True)
        signature_bytes = base64.b64decode(signature, validate=True)
        parsed = serialization.load_der_public_key(key_bytes)
    except (ValueError, TypeError, binascii.Error) as error:
        raise ValueError("Invalid device proof") from error
    if not isinstance(parsed, ec.EllipticCurvePublicKey) or not isinstance(
        parsed.curve, ec.SECP256R1
    ):
        raise ValueError("Invalid device proof")  # noqa: TRY004
    try:
        parsed.verify(
            signature_bytes,
            challenge.encode("utf-8"),
            ec.ECDSA(hashes.SHA256()),
        )
    except InvalidSignature as error:
        raise ValueError("Invalid device proof") from error
    normalized = base64.b64encode(key_bytes).decode("ascii")
    return normalized, hashlib.sha256(key_bytes).hexdigest()
