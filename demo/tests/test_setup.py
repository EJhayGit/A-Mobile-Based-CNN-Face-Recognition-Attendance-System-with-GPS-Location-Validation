import contextlib
import hashlib
import importlib.util
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "demo" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "local"
        self.module = load("configure")

    def test_first_run_creates_private_credentials_without_printing_them(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            values = self.module.create_configuration(self.path)
        self.assertEqual(values["DEMO_BIND_ADDRESS"], "127.0.0.1")
        self.assertEqual(values["DEMO_HTTP_PORT"], "8080")
        for key in [
            "DEMO_DB_ADMIN_PASSWORD",
            "DEMO_DB_APP_PASSWORD",
            "DEMO_JWT_SECRET",
            "DEMO_MANAGER_PASSWORD",
        ]:
            self.assertGreaterEqual(len(values[key]), 32)
            self.assertNotIn(values[key], output.getvalue())
        self.assertTrue((self.path / ".env").is_file())
        self.assertIn(
            values["DEMO_MANAGER_PASSWORD"],
            (self.path / "manager-login.txt").read_text(),
        )

    def test_restart_preserves_every_secret_and_instance(self):
        first = self.module.create_configuration(self.path)
        original = (self.path / ".env").read_bytes()
        second = self.module.create_configuration(self.path)
        self.assertEqual(first, second)
        self.assertEqual(original, (self.path / ".env").read_bytes())

    def test_explicit_lan_and_port_change_preserves_credentials(self):
        first = self.module.create_configuration(self.path)
        changed = self.module.create_configuration(
            self.path, bind_address="192.168.1.20", port=8081
        )
        self.assertEqual(changed["DEMO_BIND_ADDRESS"], "192.168.1.20")
        self.assertEqual(changed["DEMO_HTTP_PORT"], "8081")
        for key in first:
            if key not in ["DEMO_BIND_ADDRESS", "DEMO_HTTP_PORT"]:
                self.assertEqual(first[key], changed[key])

    def test_refuses_public_or_unspecified_bind_and_invalid_ports(self):
        for address in ["0.0.0.0", "8.8.8.8", "bad-host", "::"]:
            with self.subTest(address=address), self.assertRaises(ValueError):
                self.module.create_configuration(self.path, bind_address=address)
        for port in [0, 80, 65536, "not-a-port"]:
            with self.subTest(port=port), self.assertRaises(ValueError):
                self.module.create_configuration(self.path, port=port)

    def test_refuses_partial_config_without_replacing_it(self):
        self.path.mkdir()
        (self.path / ".env").write_text("DEMO_MANAGER_PASSWORD=some-private-value\n")
        original = (self.path / ".env").read_bytes()
        with self.assertRaises(ValueError):
            self.module.create_configuration(self.path)
        self.assertEqual(original, (self.path / ".env").read_bytes())


class InitializationGuardTests(unittest.TestCase):
    def setUp(self):
        self.module = load("initialize")

    def test_only_empty_unmarked_database_is_new(self):
        self.assertTrue(self.module.validate_installation(None, "instance", "hash", []))
        with self.assertRaises(RuntimeError):
            self.module.validate_installation(None, "instance", "hash", ["accounts"])

    def test_same_installation_can_restart_but_other_state_is_refused(self):
        marker = {"instance_id": "instance", "migration_digest": "hash"}
        self.assertFalse(
            self.module.validate_installation(marker, "instance", "hash", ["accounts"])
        )
        for instance, digest in [("other", "hash"), ("instance", "changed")]:
            with self.assertRaises(RuntimeError):
                self.module.validate_installation(
                    marker, instance, digest, ["accounts"]
                )

    def test_single_sql_bundle_matches_original_ordered_migrations(self):
        expected = "-- Fresh demo initialization only; run through demo/initialize.py.\n"
        for name in sorted(self.module.EXPECTED_MIGRATIONS):
            source = ROOT / "supabase/migrations" / name
            expected += f"\n-- Source: {name}\n" + source.read_text().rstrip() + "\n"
        actual = self.module.validate_initialization(ROOT / "demo/init.sql")
        self.assertEqual(actual, expected)

    def test_missing_changed_or_directory_bundle_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "init.sql"
            for invalid in [path, Path(tmp)]:
                with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                    self.module.validate_initialization(invalid)
            shutil.copyfile(ROOT / "demo/init.sql", path)
            path.write_bytes(path.read_bytes() + b"\n-- altered\n")
            with self.assertRaises(RuntimeError):
                self.module.validate_initialization(path)

    def test_windows_line_endings_are_accepted_and_other_sql_is_not_loaded(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "init.sql"
            expected = (ROOT / "demo/init.sql").read_text()
            path.write_bytes(expected.replace("\n", "\r\n").encode())
            (Path(tmp) / "unexpected.sql").write_text("DROP SCHEMA public CASCADE;")
            self.assertEqual(self.module.validate_initialization(path), expected)

    def test_original_installation_digest_remains_compatible(self):
        hashes = {
            p.name: hashlib.sha256(p.read_text().encode()).hexdigest()
            for p in (ROOT / "supabase/migrations").glob("*.sql")
        }
        legacy = hashlib.sha256(
            json.dumps(
                dict(sorted(hashes.items())), separators=(",", ":"), ensure_ascii=True
            ).encode("ascii")
        ).hexdigest()
        self.assertEqual(hashes, self.module.EXPECTED_MIGRATIONS)
        self.assertEqual(self.module.migration_digest(hashes), legacy)
        marker = {"instance_id": "same-instance", "migration_digest": legacy}
        self.assertFalse(
            self.module.validate_installation(
                marker,
                "same-instance",
                self.module.migration_digest(self.module.EXPECTED_MIGRATIONS),
                ["accounts"],
            )
        )

    def test_compose_mounts_only_the_single_initialization_sql(self):
        compose = (ROOT / "demo/compose.yaml").read_text()
        self.assertIn("source: ./init.sql", compose)
        self.assertIn("target: /demo/init.sql", compose)
        self.assertIn("create_host_path: false", compose)
        self.assertNotIn("../supabase/migrations", compose)


if __name__ == "__main__":
    unittest.main()
