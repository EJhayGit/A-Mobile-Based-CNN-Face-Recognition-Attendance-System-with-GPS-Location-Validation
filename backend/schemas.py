"""Validated request/response contracts."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, model_validator


class LoginRequest(BaseModel):
    login_id: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=8, max_length=256)
    device_label: str | None = Field(default=None, max_length=120)


class DriverLoginRequest(LoginRequest):
    device_public_key: str = Field(min_length=1, max_length=2048)
    device_challenge: str = Field(min_length=1, max_length=2048)
    device_signature: str = Field(min_length=1, max_length=2048)


class DriverCreateRequest(BaseModel):
    employee_id: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9._-]+$")
    full_name: str = Field(min_length=1, max_length=200)
    phone: str | None = Field(default=None, max_length=40)
    notes: str | None = Field(default=None, max_length=2000)


class DriverActivateRequest(BaseModel):
    employee_id: str = Field(min_length=1, max_length=64)
    activation_code: str = Field(min_length=6, max_length=32)
    password: str = Field(min_length=10, max_length=256)
    device_label: str | None = Field(default=None, max_length=120)
    device_public_key: str = Field(min_length=1, max_length=2048)
    device_challenge: str = Field(min_length=1, max_length=2048)
    device_signature: str = Field(min_length=1, max_length=2048)


class RefreshRequest(BaseModel):
    refresh_token: str | None = None
    login_id: str = Field(min_length=1, max_length=128)
    device_public_key: str = Field(min_length=1, max_length=2048)
    device_challenge: str = Field(min_length=1, max_length=2048)
    device_signature: str = Field(min_length=1, max_length=2048)


class DeviceChallengeRequest(BaseModel):
    login_id: str = Field(min_length=1, max_length=128)
    purpose: str = Field(pattern=r"^(activate|login|refresh|replace)$")


class DeviceReplacementRequestCreate(BaseModel):
    login_id: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=8, max_length=256)
    device_label: str | None = Field(default=None, max_length=120)
    device_public_key: str = Field(min_length=1, max_length=2048)
    device_challenge: str = Field(min_length=1, max_length=2048)
    device_signature: str = Field(min_length=1, max_length=2048)


class DeviceReplacementDecisionRequest(BaseModel):
    decision: str = Field(pattern=r"^(approve|reject)$")


class PasswordChangeRequest(BaseModel):
    current_password: str = Field(min_length=8, max_length=256)
    new_password: str = Field(min_length=10, max_length=256)


class FaceReregistrationDecisionRequest(BaseModel):
    decision: str = Field(pattern=r"^(approve|reject)$")


class AttendanceUpload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    client_attempt_id: str = Field(min_length=1, max_length=128)
    driver_id: str = Field(min_length=1, max_length=128)
    site_id: str = Field(min_length=1, max_length=128)
    assignment_id: str | None = Field(default=None, min_length=1, max_length=128)
    route_stop_id: str | None = Field(default=None, min_length=1, max_length=128)
    captured_at_utc: datetime
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    gps_accuracy_meters: float = Field(ge=0)
    distance_meters: float = Field(ge=0)
    face_score: float = Field(ge=-1, le=1)
    face_verified: bool
    gps_verified: bool


class DeliveryLocationCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=160)
    address: str | None = Field(default=None, max_length=1000)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    radius_meters: int = Field(default=100, ge=10, le=5000)


class DeliveryLocationUpdateRequest(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=160)
    address: str | None = Field(default=None, max_length=1000)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    radius_meters: int | None = Field(default=None, ge=10, le=5000)
    active: bool | None = None


class DeliveryRouteStopRequest(BaseModel):
    delivery_location_id: str = Field(min_length=1, max_length=36)


class DeliveryAssignmentCreateRequest(BaseModel):
    driver_id: str = Field(min_length=1, max_length=36)
    delivery_location_id: str | None = Field(default=None, min_length=1, max_length=36)
    stops: list[DeliveryRouteStopRequest] | None = Field(
        default=None, min_length=1, max_length=50
    )
    route_name: str | None = Field(default=None, max_length=160)
    scheduled_at: datetime | None = None
    notes: str | None = Field(default=None, max_length=2000)

    @model_validator(mode="after")
    def require_route_stops(self):
        if not self.stops and not self.delivery_location_id:
            raise ValueError("At least one Site Location is required")
        if (
            self.stops
            and self.delivery_location_id
            and self.stops[0].delivery_location_id != self.delivery_location_id
        ):
            raise ValueError("The primary Site Location must match the first stop")
        return self


class DeliveryRouteStopsUpdateRequest(BaseModel):
    stops: list[DeliveryRouteStopRequest] = Field(min_length=1, max_length=50)


class DeliveryAssignmentUpdateRequest(BaseModel):
    status: str = Field(pattern=r"^(assigned|in_progress|completed|cancelled)$")
