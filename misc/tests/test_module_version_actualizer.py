#!/usr/bin/env python3
"""Honesty contract for misc/module-version-actualizer.py:

  - registry fetch failures must exit non-zero, name the failed modules, and
    leave the descriptor file untouched (no identity re-stamp on partial state)
  - a no-movement re-run must exit 0 WITHOUT minting a new application id
  - the success path still bumps the application identity
"""

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

PROJECT_ROOT = Path(__file__).resolve().parents[2]
ACTUALIZER_SCRIPT_PATH = PROJECT_ROOT / "misc" / "module-version-actualizer.py"


def load_actualizer_module():
  spec = importlib.util.spec_from_file_location("module_version_actualizer_honesty", ACTUALIZER_SCRIPT_PATH)
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  return module


def write_descriptor(path: Path) -> dict:
  descriptor = {
    "id": "app-platform-minimal-0.0.17-SNAPSHOT.2",
    "name": "app-platform-minimal",
    "version": "0.0.17-SNAPSHOT.2",
    "modules": [
      {
        "name": "mod-users",
        "id": "mod-users-19.5.3",
        "version": "19.5.3",
        "url": "https://folio-registry.dev.folio.org/_/proxy/modules/mod-users-19.5.3",
      }
    ],
  }
  path.write_text(json.dumps(descriptor, indent=2) + "\n", encoding="utf-8")
  return descriptor


class ModuleVersionActualizerHonestyTest(unittest.TestCase):

  def run_actualizer(self, descriptor_path: Path, urlopen_side_effect):
    module = load_actualizer_module()
    stdout = io.StringIO()
    stderr = io.StringIO()
    with mock.patch.object(module.urllib.request, "urlopen", side_effect=urlopen_side_effect):
      with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        exit_code = module.main(["--app", str(descriptor_path), "--pre-release", "false"])
    return exit_code, stdout.getvalue(), stderr.getvalue()

  def registry_response(self, payload: dict):
    # The registry answers with a JSON array of module descriptors; urlopen is
    # used as `with urlopen(url) as response: json.load(response)`.
    return mock.mock_open(read_data=json.dumps([payload])).return_value

  def test_all_fetches_failing_exit_nonzero_and_leave_descriptor_untouched(self):
    with tempfile.TemporaryDirectory() as temp_dir_name:
      descriptor_path = Path(temp_dir_name) / "descriptor.json"
      original_text = write_descriptor(descriptor_path) and descriptor_path.read_text(encoding="utf-8")

      def failing_urlopen(url):
        raise OSError("network down")

      exit_code, stdout, stderr = self.run_actualizer(descriptor_path, failing_urlopen)

      self.assertEqual(exit_code, 1)
      self.assertIn("mod-users", stderr)
      self.assertNotIn("updated successfully", stdout)
      self.assertEqual(descriptor_path.read_text(encoding="utf-8"), original_text)

  def test_partial_failures_name_each_failed_module_and_exit_nonzero(self):
    with tempfile.TemporaryDirectory() as temp_dir_name:
      descriptor_path = Path(temp_dir_name) / "descriptor.json"
      descriptor = write_descriptor(descriptor_path)
      descriptor["modules"].append({
        "name": "mod-login-keycloak",
        "id": "mod-login-keycloak-3.0.3",
        "version": "3.0.3",
        "url": "https://folio-registry.dev.folio.org/_/proxy/modules/mod-login-keycloak-3.0.3",
      })
      descriptor_path.write_text(json.dumps(descriptor, indent=2) + "\n", encoding="utf-8")
      original_text = descriptor_path.read_text(encoding="utf-8")

      def selective_urlopen(url):
        if "filter=mod-users" in url:
          return self.registry_response({"id": "mod-users-19.5.3"})
        raise OSError("registry unreachable")

      exit_code, stdout, stderr = self.run_actualizer(descriptor_path, selective_urlopen)

      self.assertEqual(exit_code, 1)
      self.assertIn("mod-login-keycloak", stderr)
      self.assertNotIn("mod-users", stderr)
      self.assertNotIn("updated successfully", stdout)
      self.assertEqual(descriptor_path.read_text(encoding="utf-8"), original_text)

  def test_no_movement_exits_zero_without_restamping_application_identity(self):
    with tempfile.TemporaryDirectory() as temp_dir_name:
      descriptor_path = Path(temp_dir_name) / "descriptor.json"
      write_descriptor(descriptor_path)

      def same_version_urlopen(url):
        return self.registry_response({"id": "mod-users-19.5.3"})

      exit_code, stdout, stderr = self.run_actualizer(descriptor_path, same_version_urlopen)

      self.assertEqual(exit_code, 0, stderr)
      self.assertIn("No updates were made.", stdout)
      updated_descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
      self.assertEqual(updated_descriptor["id"], "app-platform-minimal-0.0.17-SNAPSHOT.2")
      self.assertEqual(updated_descriptor["version"], "0.0.17-SNAPSHOT.2")

  def test_success_path_bumps_application_identity(self):
    with tempfile.TemporaryDirectory() as temp_dir_name:
      descriptor_path = Path(temp_dir_name) / "descriptor.json"
      write_descriptor(descriptor_path)

      def newer_version_urlopen(url):
        return self.registry_response({"id": "mod-users-19.5.4"})

      exit_code, stdout, stderr = self.run_actualizer(descriptor_path, newer_version_urlopen)

      self.assertEqual(exit_code, 0, stderr)
      self.assertIn("Application descriptor module versions updated successfully!", stdout)
      self.assertIn("mod-users 19.5.3 -> 19.5.4", stdout)
      self.assertIn("application descriptor ->", stdout)
      updated_descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
      self.assertNotEqual(updated_descriptor["id"], "app-platform-minimal-0.0.17-SNAPSHOT.2")
      self.assertTrue(updated_descriptor["id"].startswith("app-platform-minimal-0.0.17-SNAPSHOT."))
      self.assertEqual(updated_descriptor["modules"][0]["version"], "19.5.4")


if __name__ == "__main__":
  unittest.main()
