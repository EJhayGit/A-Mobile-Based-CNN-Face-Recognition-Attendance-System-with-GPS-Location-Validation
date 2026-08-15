"""Legacy mobile-payload validator retained as a compatibility contract."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime
from math import isfinite
from typing import Any


@dataclass(frozen=True)
class AttendanceRecord:
    client_attempt_id: str
    driver_id: str
    site_id: str
    captured_at_utc: str
    latitude: float
    longitude: float
    gps_accuracy_meters: float
    distance_meters: float
    face_score: float
    face_verified: bool
    gps_verified: bool

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> AttendanceRecord:
        required = {field.name for field in cls.__dataclass_fields__.values()}
        if set(payload) != required:
            missing = sorted(required - set(payload))
            extra = sorted(set(payload) - required)
            raise ValueError(
                f"Invalid attendance fields; missing={missing}, extra={extra}."
            )
        record = cls(**payload)
        if not record.client_attempt_id or not record.driver_id or not record.site_id:
            raise ValueError("Attempt, driver, and site identifiers must be non-empty.")
        parsed_time = datetime.fromisoformat(
            record.captured_at_utc.replace("Z", "+00:00")
        )
        if parsed_time.tzinfo is None:
            raise ValueError("captured_at_utc must include a timezone.")
        if not record.face_verified or not record.gps_verified:
            raise ValueError(
                "Only locally accepted face-and-GPS records may synchronize."
            )
        numeric_values = (
            record.latitude,
            record.longitude,
            record.gps_accuracy_meters,
            record.distance_meters,
            record.face_score,
        )
        if not all(
            isinstance(value, (int, float)) and isfinite(value)
            for value in numeric_values
        ):
            raise ValueError("Numeric attendance values must be finite.")
        if not (-90 <= record.latitude <= 90 and -180 <= record.longitude <= 180):
            raise ValueError("Coordinates are outside valid ranges.")
        if record.gps_accuracy_meters < 0 or record.distance_meters < 0:
            raise ValueError("GPS accuracy and distance must be non-negative.")
        if not (-1 <= record.face_score <= 1):
            raise ValueError("Cosine face_score must be within [-1, 1].")
        return record

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
