"""Persistent account, session, audit, and attendance models."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    JSON,
    Boolean,
    CheckConstraint,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy import (
    text as sql_text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from backend.database import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def new_id() -> str:
    return str(uuid.uuid4())


class Account(Base):
    __tablename__ = "accounts"
    __table_args__ = (
        CheckConstraint(
            "role in ('fleet_manager','driver')", name="accounts_role_check"
        ),
        CheckConstraint(
            "status in ('pending_activation','active','disabled')",
            name="accounts_status_check",
        ),
        Index(
            "accounts_current_driver_status_idx",
            "role",
            "status",
            postgresql_where=sql_text("deleted_at is null"),
            sqlite_where=sql_text("deleted_at is null"),
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    role: Mapped[str] = mapped_column(String(32), nullable=False)
    login_id: Mapped[str] = mapped_column(String(128), nullable=False, unique=True)
    password_hash: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(32), nullable=False)
    password_changed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )
    disabled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    driver_profile: Mapped[DriverProfile | None] = relationship(
        back_populates="account", uselist=False, foreign_keys="DriverProfile.account_id"
    )
    delivery_assignments: Mapped[list[DeliveryAssignment]] = relationship(
        back_populates="driver", foreign_keys="DeliveryAssignment.driver_account_id"
    )


class DriverProfile(Base):
    __tablename__ = "driver_profiles"

    account_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    employee_id: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    full_name: Mapped[str] = mapped_column(String(200), nullable=False)
    phone: Mapped[str | None] = mapped_column(String(40))
    notes: Mapped[str | None] = mapped_column(Text)
    created_by_manager_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )

    account: Mapped[Account] = relationship(
        back_populates="driver_profile", foreign_keys=[account_id]
    )


class ActivationCode(Base):
    __tablename__ = "activation_codes"
    __table_args__ = (
        CheckConstraint("failed_attempt_count >= 0", name="activation_attempts_check"),
        Index(
            "activation_codes_current_idx",
            "driver_account_id",
            "expires_at",
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    driver_account_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False
    )
    code_hash: Mapped[str] = mapped_column(Text, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    invalidated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    failed_attempt_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0
    )
    created_by_manager_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )


class AuthSession(Base):
    __tablename__ = "auth_sessions"
    __table_args__ = (
        Index("auth_sessions_account_active_idx", "account_id", "expires_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    account_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False
    )
    refresh_token_hash: Mapped[str] = mapped_column(
        String(64), nullable=False, unique=True
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    device_label: Mapped[str | None] = mapped_column(String(120))


class DeliveryLocation(Base):
    __tablename__ = "delivery_locations"
    __table_args__ = (
        CheckConstraint(
            "latitude between -90 and 90", name="delivery_locations_latitude_check"
        ),
        CheckConstraint(
            "longitude between -180 and 180",
            name="delivery_locations_longitude_check",
        ),
        CheckConstraint(
            "radius_meters between 10 and 5000",
            name="delivery_locations_radius_check",
        ),
        Index("delivery_locations_active_name_idx", "active", "name"),
        Index(
            "delivery_locations_current_name_idx",
            "name",
            postgresql_where=sql_text("deleted_at is null"),
            sqlite_where=sql_text("deleted_at is null"),
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    address: Mapped[str | None] = mapped_column(Text)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    radius_meters: Mapped[int] = mapped_column(Integer, nullable=False, default=100)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    assignments: Mapped[list[DeliveryAssignment]] = relationship(
        back_populates="location"
    )


class DeliveryAssignment(Base):
    __tablename__ = "delivery_assignments"
    __table_args__ = (
        CheckConstraint(
            "status in ('assigned','in_progress','completed','cancelled')",
            name="delivery_assignments_status_check",
        ),
        Index(
            "delivery_assignments_one_active_driver_idx",
            "driver_account_id",
            unique=True,
            postgresql_where=sql_text("status in ('assigned','in_progress')"),
            sqlite_where=sql_text("status in ('assigned','in_progress')"),
        ),
        Index("delivery_assignments_status_assigned_idx", "status", "assigned_at"),
        Index("delivery_assignments_location_idx", "delivery_location_id"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    driver_account_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False
    )
    delivery_location_id: Mapped[str] = mapped_column(
        ForeignKey("delivery_locations.id", ondelete="RESTRICT"), nullable=False
    )
    assigned_by_manager_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False
    )
    assigned_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )
    scheduled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="assigned")
    notes: Mapped[str | None] = mapped_column(Text)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )

    driver: Mapped[Account] = relationship(
        back_populates="delivery_assignments", foreign_keys=[driver_account_id]
    )
    location: Mapped[DeliveryLocation] = relationship(back_populates="assignments")


class AttendanceRecord(Base):
    __tablename__ = "attendance_records"
    __table_args__ = (
        UniqueConstraint("client_attempt_id", name="attendance_client_attempt_id_key"),
        CheckConstraint(
            "latitude between -90 and 90", name="attendance_latitude_check"
        ),
        CheckConstraint(
            "longitude between -180 and 180", name="attendance_longitude_check"
        ),
        CheckConstraint("gps_accuracy_meters >= 0", name="attendance_accuracy_check"),
        CheckConstraint("distance_meters >= 0", name="attendance_distance_check"),
        CheckConstraint(
            "face_score between -1 and 1", name="attendance_face_score_check"
        ),
        Index("attendance_driver_captured_idx", "driver_account_id", "captured_at_utc"),
        Index("attendance_captured_idx", "captured_at_utc"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    client_attempt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    driver_account_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False
    )
    client_driver_id: Mapped[str] = mapped_column(String(128), nullable=False)
    site_id: Mapped[str] = mapped_column(String(128), nullable=False)
    captured_at_utc: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    gps_accuracy_meters: Mapped[float] = mapped_column(Float, nullable=False)
    distance_meters: Mapped[float] = mapped_column(Float, nullable=False)
    face_score: Mapped[float] = mapped_column(Float, nullable=False)
    face_verified: Mapped[bool] = mapped_column(Boolean, nullable=False)
    gps_verified: Mapped[bool] = mapped_column(Boolean, nullable=False)
    server_received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )


class AccountAuditLog(Base):
    __tablename__ = "account_audit_logs"
    __table_args__ = (
        Index("account_audit_target_created_idx", "target_account_id", "created_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    actor_account_id: Mapped[str | None] = mapped_column(
        ForeignKey("accounts.id", ondelete="SET NULL")
    )
    target_account_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False
    )
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    safe_metadata: Mapped[dict[str, object]] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )
