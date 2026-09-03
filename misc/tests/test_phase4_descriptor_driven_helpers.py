#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from unittest import mock
from collections import OrderedDict
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUN_SCRIPT_PATH = PROJECT_ROOT / "misc" / "docker-module-updater" / "run.py"
ACTUALIZER_SCRIPT_PATH = PROJECT_ROOT / "misc" / "module-version-actualizer.py"
DEFAULT_DESCRIPTOR_PATH = PROJECT_ROOT / "descriptors" / "app-platform-minimal" / "descriptor.json"
ENV_LOCAL_PATH = PROJECT_ROOT / "docker" / ".env.local"


def load_run_module():
  spec = importlib.util.spec_from_file_location("phase4_run", RUN_SCRIPT_PATH)
  module = importlib.util.module_from_spec(spec)
  assert spec.loader is not None
  spec.loader.exec_module(module)
  return module


def load_actualizer_module():
  spec = importlib.util.spec_from_file_location("module_version_actualizer", ACTUALIZER_SCRIPT_PATH)
  module = importlib.util.module_from_spec(spec)
  assert spec.loader is not None
  spec.loader.exec_module(module)
  return module


class Phase4DescriptorDrivenHelpersTest(unittest.TestCase):
  def test_module_version_actualizer_help_exposes_app_option(self):
    result = subprocess.run(
      ["python3", str(ACTUALIZER_SCRIPT_PATH), "--help"],
      cwd=PROJECT_ROOT,
      text=True,
      input="",
      capture_output=True,
    )

    self.assertEqual(result.returncode, 0)
    self.assertIn("--app", result.stdout)

  def test_module_version_actualizer_help_exposes_pre_release_option(self):
    result = subprocess.run(
      ["python3", str(ACTUALIZER_SCRIPT_PATH), "--help"],
      cwd=PROJECT_ROOT,
      text=True,
      input="",
      capture_output=True,
    )

    self.assertEqual(result.returncode, 0)
    self.assertIn("--pre-release", result.stdout)

  def test_module_version_actualizer_main_uses_non_interactive_pre_release_selector(self):
    module = load_actualizer_module()

    with tempfile.TemporaryDirectory() as temp_dir_name:
      descriptor_path = Path(temp_dir_name) / "descriptor.json"
      descriptor_path.write_text(
        json.dumps({
          "modules": [
            {
              "name": "mod-users",
              "id": "mod-users-19.5.3",
              "version": "19.5.3",
              "url": "https://folio-registry.dev.folio.org/_/proxy/modules/mod-users-19.5.3",
            }
          ]
        }, indent=2) + "\n",
        encoding="utf-8",
      )

      stdout = io.StringIO()
      stderr = io.StringIO()
      with mock.patch.object(module, "prompt_for_pre_release", side_effect=AssertionError("prompt should not be used")):
        with mock.patch.object(module, "fetch_module_data", return_value={"id": "mod-users-19.5.4"}):
          with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            exit_code = module.main([
              "--app",
              str(descriptor_path),
              "--pre-release",
              "false",
            ])

      self.assertEqual(exit_code, 0, stderr.getvalue())
      self.assertIn("Application descriptor module versions updated successfully!", stdout.getvalue())
      updated_descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
      self.assertEqual(updated_descriptor["modules"][0]["version"], "19.5.4")

  def test_module_version_actualizer_refreshes_application_identity(self):
    module = load_actualizer_module()

    descriptor = {
      "id": "app-platform-minimal-0.0.17-SNAPSHOT.2",
      "name": "app-platform-minimal",
      "version": "0.0.17-SNAPSHOT.2",
      "modules": [],
    }

    with mock.patch.object(module, "build_application_version", return_value="0.0.17-SNAPSHOT.20260426183000"):
      new_version = module.refresh_application_identity(descriptor)

    self.assertEqual(new_version, "0.0.17-SNAPSHOT.20260426183000")
    self.assertEqual(descriptor["version"], "0.0.17-SNAPSHOT.20260426183000")
    self.assertEqual(descriptor["id"], "app-platform-minimal-0.0.17-SNAPSHOT.20260426183000")

  def test_get_service_list_preserves_descriptor_order(self):
    module = load_run_module()
    module_versions = OrderedDict([
      ("mod-users", "19.5.4"),
      ("mod-login-keycloak", "3.0.4"),
      ("mod-users-keycloak", "3.0.12"),
    ])

    service_list = module.get_service_list(
      module_versions,
      {"mod-users", "mod-login-keycloak", "mod-users-keycloak"},
      {"sc-users", "sc-login-keycloak", "sc-users-keycloak"},
    )

    self.assertEqual(service_list, [
      "mod-users",
      "sc-users",
      "mod-login-keycloak",
      "sc-login-keycloak",
      "mod-users-keycloak",
      "sc-users-keycloak",
    ])

  def test_get_service_list_reports_missing_service_pairs(self):
    module = load_run_module()
    module_versions = OrderedDict([("mod-users-keycloak", "3.0.12")])

    with self.assertRaisesRegex(ValueError, "sc-users-keycloak"):
      module.get_service_list(
        module_versions,
        {"mod-users-keycloak"},
        set(),
      )

  def test_services_mode_uses_explicit_descriptor_without_side_effects(self):
    module = load_run_module()
    original_env_local = ENV_LOCAL_PATH.read_text(encoding="utf-8")

    with tempfile.TemporaryDirectory() as temp_dir_name:
      temp_dir = Path(temp_dir_name)
      descriptor = json.loads(DEFAULT_DESCRIPTOR_PATH.read_text(encoding="utf-8"))
      descriptor["modules"] = [
        module_entry for module_entry in descriptor["modules"]
        if module_entry["name"] in {"mod-users", "mod-login-keycloak", "mod-users-keycloak"}
      ]
      descriptor_path = temp_dir / "descriptor.json"
      descriptor_path.write_text(json.dumps(descriptor, indent=2) + "\n", encoding="utf-8")

      stdout = io.StringIO()
      stderr = io.StringIO()
      with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        exit_code = module.main(["--app", str(descriptor_path), "--services"])

      self.assertEqual(exit_code, 0, stderr.getvalue())
      self.assertEqual(
        stdout.getvalue(),
        "mod-users sc-users mod-login-keycloak sc-login-keycloak mod-users-keycloak sc-users-keycloak\n",
      )
      self.assertEqual(ENV_LOCAL_PATH.read_text(encoding="utf-8"), original_env_local)
      self.assertFalse((temp_dir / "discovery.json").exists())

  def test_cleanup_module_runtime_metadata_preserves_standalone_module_overrides(self):
    module = load_run_module()
    module_versions = OrderedDict([
      ("mod-users", "19.5.4"),
      ("mod-login-keycloak", "3.0.4"),
      ("mod-scheduler", "3.0.8-SNAPSHOT.1"),
    ])

    with tempfile.TemporaryDirectory() as temp_dir_name:
      env_local_path = Path(temp_dir_name) / ".env.local"
      env_local_path.write_text(
        "KC_LOGIN_CLIENT_SUFFIX=-login-app\n"
        "export MOD_USERS_VERSION=old-users\n"
        "export MOD_USERS_IMAGE=custom/mod-users:manual\n"
        "export MOD_USERS_REPOSITORY=folioorg/mod-users\n"
        "export MOD_LOGIN_KEYCLOAK_REPOSITORY=folioorg/mod-login-keycloak\n"
        "export MOD_NOTES_VERSION=keep-me\n",
        encoding="utf-8",
      )

      module.cleanup_module_runtime_metadata(
        env_local_path,
        module_versions,
        {"mod-users", "mod-login-keycloak", "mod-scheduler", "mod-notes"},
      )

      updated_lines = env_local_path.read_text(encoding="utf-8")
      self.assertIn("KC_LOGIN_CLIENT_SUFFIX=-login-app\n", updated_lines)
      self.assertIn("export MOD_USERS_IMAGE=custom/mod-users:manual\n", updated_lines)
      self.assertIn("export MOD_USERS_VERSION=old-users\n", updated_lines)
      self.assertNotIn("MOD_USERS_REPOSITORY", updated_lines)
      self.assertNotIn("MOD_LOGIN_KEYCLOAK_REPOSITORY", updated_lines)
      self.assertIn("export MOD_NOTES_VERSION=keep-me\n", updated_lines)
      self.assertNotIn("folioorg/mod-users:19.5.4", updated_lines)

  def test_cleanup_module_runtime_metadata_preserves_manual_image_and_version_override(self):
    module = load_run_module()
    module_versions = OrderedDict([("mod-users", "19.6.0")])

    with tempfile.TemporaryDirectory() as temp_dir_name:
      env_local_path = Path(temp_dir_name) / ".env.local"
      env_local_path.write_text(
        "export MOD_USERS_IMAGE=custom/mod-users:test\n"
        "export MOD_USERS_VERSION=manual-version\n",
        encoding="utf-8",
      )

      module.cleanup_module_runtime_metadata(env_local_path, module_versions, {"mod-users"})

      updated_lines = env_local_path.read_text(encoding="utf-8")
      self.assertIn("export MOD_USERS_IMAGE=custom/mod-users:test\n", updated_lines)
      self.assertIn("export MOD_USERS_VERSION=manual-version\n", updated_lines)

  def test_cleanup_module_runtime_metadata_is_idempotent(self):
    module = load_run_module()
    module_versions = OrderedDict([
      ("mod-users", "19.6.0"),
      ("mod-login-keycloak", "4.0.1"),
    ])
    known = {"mod-users", "mod-login-keycloak", "mod-notes"}

    with tempfile.TemporaryDirectory() as temp_dir_name:
      env_local_path = Path(temp_dir_name) / ".env.local"
      # Realistic input with the two scattered legacy generated regions.
      env_local_path.write_text(
        "KC_LOGIN_CLIENT_SUFFIX=-login-app\n"
        "\n"
        "# generated module versions\n"
        "export MOD_USERS_VERSION=old\n"
        "export MOD_NOTES_VERSION=stale\n"
        "\n"
        "FOLIO_KEYCLOAK_IMAGE=keycloak-latest\n"
        "KC_SERVICE_CLIENT_ID=m2m-client\n"
        "\n"
        "# generated module images and versions\n"
        "export MOD_USERS_IMAGE=folioorg/mod-users:old\n",
        encoding="utf-8",
      )

      module.cleanup_module_runtime_metadata(env_local_path, module_versions, known)
      first = env_local_path.read_text(encoding="utf-8")
      module.cleanup_module_runtime_metadata(env_local_path, module_versions, known)
      second = env_local_path.read_text(encoding="utf-8")

      self.assertEqual(first, second)
      self.assertNotIn("# BEGIN generated module runtime metadata", first)
      self.assertNotIn("# END generated module runtime metadata", first)
      self.assertNotIn("MOD_USERS_VERSION", first)
      self.assertNotIn("MOD_USERS_IMAGE", first)

  def test_cleanup_module_runtime_metadata_removes_legacy_blocks(self):
    module = load_run_module()
    module_versions = OrderedDict([("mod-users", "19.6.0")])
    known = {"mod-users", "mod-notes"}

    with tempfile.TemporaryDirectory() as temp_dir_name:
      env_local_path = Path(temp_dir_name) / ".env.local"
      env_local_path.write_text(
        "KC_LOGIN_CLIENT_SUFFIX=-login-app\n"
        "# generated module versions\n"
        "export MOD_USERS_VERSION=old\n"
        "export MOD_NOTES_VERSION=stale\n"
        "FOLIO_KEYCLOAK_IMAGE=keycloak-latest\n"
        "KC_SERVICE_CLIENT_ID=m2m-client\n"
        "# generated module images and versions\n"
        "export MOD_USERS_IMAGE=folioorg/mod-users:old\n",
        encoding="utf-8",
      )

      module.cleanup_module_runtime_metadata(env_local_path, module_versions, known)
      updated = env_local_path.read_text(encoding="utf-8")

      self.assertNotIn("# generated module versions\n", updated)
      self.assertNotIn("# generated module images and versions\n", updated)
      self.assertNotIn("# BEGIN generated module runtime metadata", updated)
      self.assertIn("KC_LOGIN_CLIENT_SUFFIX=-login-app\n", updated)
      self.assertIn("FOLIO_KEYCLOAK_IMAGE=keycloak-latest\n", updated)
      self.assertIn("KC_SERVICE_CLIENT_ID=m2m-client\n", updated)
      self.assertNotIn("MOD_NOTES", updated)
      self.assertNotIn("MOD_USERS_IMAGE", updated)
      self.assertNotIn("MOD_USERS_VERSION", updated)

  def test_print_module_env_exports_descriptor_derived_runtime_vars(self):
    module = load_run_module()
    module_versions = OrderedDict([
      ("mod-users", "19.5.4"),
      ("mod-scheduler", "3.0.8-SNAPSHOT.1"),
    ])

    stdout = io.StringIO()
    with contextlib.redirect_stdout(stdout):
      module.print_module_env_exports(module_versions)

    self.assertEqual(stdout.getvalue(), (
      "export MOD_USERS_IMAGE=folioorg/mod-users:19.5.4\n"
      "export MOD_USERS_VERSION=19.5.4\n"
      "export MOD_SCHEDULER_IMAGE=folioci/mod-scheduler:3.0.8-SNAPSHOT.1\n"
      "export MOD_SCHEDULER_VERSION=3.0.8-SNAPSHOT.1\n"
    ))

  def test_module_env_mode_uses_explicit_descriptor_without_side_effects(self):
    module = load_run_module()
    original_env_local = ENV_LOCAL_PATH.read_text(encoding="utf-8")

    with tempfile.TemporaryDirectory() as temp_dir_name:
      temp_dir = Path(temp_dir_name)
      descriptor_path = temp_dir / "descriptor.json"
      descriptor_path.write_text(
        json.dumps({
          "modules": [
            {"name": "mod-users", "version": "19.5.4"},
            {"name": "mod-scheduler", "version": "3.0.8-SNAPSHOT.1"},
          ]
        }, indent=2) + "\n",
        encoding="utf-8",
      )

      stdout = io.StringIO()
      stderr = io.StringIO()
      with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        exit_code = module.main(["--app", str(descriptor_path), "--module-env"])

      self.assertEqual(exit_code, 0, stderr.getvalue())
      self.assertIn("export MOD_USERS_IMAGE=folioorg/mod-users:19.5.4\n", stdout.getvalue())
      self.assertIn("export MOD_SCHEDULER_IMAGE=folioci/mod-scheduler:3.0.8-SNAPSHOT.1\n", stdout.getvalue())
      self.assertEqual(ENV_LOCAL_PATH.read_text(encoding="utf-8"), original_env_local)
      self.assertFalse((temp_dir / "discovery.json").exists())


if __name__ == "__main__":
  unittest.main()
