from __future__ import annotations

import unittest

from backend.attendance import AttendanceRecord


def payload(attempt_id: str = "attempt-1") -> dict[str, object]:
    return {
        "client_attempt_id": attempt_id,
        "driver_id": "driver-1",
        "site_id": "depot-1",
        "captured_at_utc": "2026-07-30T01:02:03+00:00",
        "latitude": 14.5995,
        "longitude": 120.9842,
        "gps_accuracy_meters": 5.0,
        "distance_meters": 3.0,
        "face_score": 0.75,
        "face_verified": True,
        "gps_verified": True,
    }


class AttendanceContractTests(unittest.TestCase):
    def test_valid_mobile_payload_round_trips(self) -> None:
        self.assertEqual(AttendanceRecord.from_payload(payload()).to_dict(), payload())
        bound = {
            **payload(),
            "assignment_id": "assignment-1",
            "route_stop_id": "stop-1",
        }
        self.assertEqual(AttendanceRecord.from_payload(bound).to_dict(), bound)

    def test_missing_or_extra_fields_are_rejected(self) -> None:
        missing = payload()
        del missing["site_id"]
        with self.assertRaisesRegex(ValueError, "missing"):
            AttendanceRecord.from_payload(missing)
        extra = payload()
        extra["unexpected"] = True
        with self.assertRaisesRegex(ValueError, "extra"):
            AttendanceRecord.from_payload(extra)

    def test_unverified_or_invalid_record_is_rejected(self) -> None:
        invalid = payload()
        invalid["gps_verified"] = False
        with self.assertRaisesRegex(ValueError, "locally accepted"):
            AttendanceRecord.from_payload(invalid)
        invalid_numeric = payload()
        invalid_numeric["gps_accuracy_meters"] = float("nan")
        with self.assertRaisesRegex(ValueError, "finite"):
            AttendanceRecord.from_payload(invalid_numeric)


if __name__ == "__main__":
    unittest.main()
