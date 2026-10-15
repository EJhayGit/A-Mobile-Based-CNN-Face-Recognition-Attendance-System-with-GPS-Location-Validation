import contextlib
import importlib.util
import io
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

    def test_migrations_must_match_bundle_exactly(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            for source in (ROOT / "supabase/migrations").glob("*.sql"):
                shutil.copyfile(source, folder / source.name)
            self.assertEqual(len(self.module.validate_migrations(folder)), 8)
            first = min(folder.glob("*.sql"))
            first.write_bytes(first.read_bytes() + b"\n-- altered\n")
            with self.assertRaises(RuntimeError):
                self.module.validate_migrations(folder)

    def test_missing_migration_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(RuntimeError):
            self.module.validate_migrations(Path(tmp))


if __name__ == "__main__":
    unittest.main()
