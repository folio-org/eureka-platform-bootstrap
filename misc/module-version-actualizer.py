#!/usr/bin/env python3

import argparse
import json
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_APP_DESCRIPTOR_PATH = PROJECT_ROOT / "descriptors" / "app-platform-minimal" / "descriptor.json"


def parse_pre_release_selector(value: str) -> str:
  normalized_value = value.strip().lower()
  if normalized_value not in ("true", "false", "prompt"):
    raise argparse.ArgumentTypeError("must be one of: true, false, prompt")
  return normalized_value


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
  parser = argparse.ArgumentParser(
    description="Refresh descriptor module versions from the FOLIO registry.",
  )
  parser.add_argument(
    "--app",
    default=str(DEFAULT_APP_DESCRIPTOR_PATH),
    help="Path to the application descriptor to update.",
  )
  parser.add_argument(
    "--pre-release",
    type=parse_pre_release_selector,
    default="prompt",
    help="Select pre-release handling: true, false, or prompt (default).",
  )
  return parser.parse_args(argv)


def resolve_descriptor_path(app_path: str) -> Path:
  descriptor_path = Path(app_path).expanduser()
  if not descriptor_path.is_absolute():
    descriptor_path = (Path.cwd() / descriptor_path).resolve()
  else:
    descriptor_path = descriptor_path.resolve()

  if not descriptor_path.is_file():
    raise FileNotFoundError(f"Descriptor file not found: {descriptor_path}")

  return descriptor_path


def prompt_for_pre_release() -> bool:
  answer = input(
    "Use latest SNAPSHOT versions (if `no` latest release versions will be used)? [y/N]: "
  ).strip().lower()
  return answer in ("y", "yes")


def fetch_module_data(module_name: str, pre_release: bool) -> dict | None:
  pre_release_value = "true" if pre_release else "false"
  url = (
    "https://folio-registry.dev.folio.org/_/proxy/modules"
    f"?preRelease={pre_release_value}&latest=1&filter={module_name}"
  )
  try:
    with urllib.request.urlopen(url) as response:
      module_data = json.load(response)
  except Exception as error:
    print(f"Error fetching data for module {module_name}: {error}", file=sys.stderr)
    return None

  if isinstance(module_data, list) and module_data:
    return module_data[0]
  return None


def extract_version(module_id: str) -> str:
  match = re.search(r"-(\d+\.\d+\.\d+(?:-SNAPSHOT\.\d+)?)$", module_id)
  return match.group(1) if match else module_id.split("-")[-1]


def build_application_version(current_version: str) -> str:
  timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
  base_version = current_version.split("-SNAPSHOT.", 1)[0]
  return f"{base_version}-SNAPSHOT.{timestamp}"


def refresh_application_identity(app_descriptor: dict) -> str | None:
  app_name = app_descriptor.get("name")
  current_version = app_descriptor.get("version")

  if not app_name or not current_version:
    return None

  new_version = build_application_version(current_version)
  app_descriptor["version"] = new_version
  app_descriptor["id"] = f"{app_name}-{new_version}"
  return new_version


def update_descriptor(descriptor_path: Path, pre_release: bool) -> list[str]:
  with descriptor_path.open("r", encoding="utf-8") as file_handle:
    app_descriptor = json.load(file_handle)

  updated_modules: list[str] = []
  for module in app_descriptor.get("modules", []):
    module_name = module.get("name")
    old_version = module.get("version")
    updated_module = fetch_module_data(module_name, pre_release)
    if not updated_module:
      continue

    new_version = extract_version(updated_module["id"])
    if old_version != new_version:
      updated_modules.append(f" - {module_name} {old_version} -> {new_version}")

    module["id"] = updated_module["id"]
    module["version"] = new_version
    module["url"] = (
      "https://folio-registry.dev.folio.org/_/proxy/modules/"
      f"{updated_module['id']}"
    )

  new_application_version = refresh_application_identity(app_descriptor)
  if new_application_version:
    updated_modules.append(f" - application descriptor -> {new_application_version}")

  with descriptor_path.open("w", encoding="utf-8", newline="\n") as file_handle:
    json.dump(app_descriptor, file_handle, indent=2, ensure_ascii=False)
    file_handle.write("\n")

  return updated_modules


def main(argv: list[str] | None = None) -> int:
  args = parse_args(argv)

  try:
    descriptor_path = resolve_descriptor_path(args.app)
  except FileNotFoundError as error:
    print(error, file=sys.stderr)
    return 1

  if args.pre_release == "prompt":
    pre_release = prompt_for_pre_release()
  else:
    pre_release = args.pre_release == "true"
  updated_modules = update_descriptor(descriptor_path, pre_release)

  print("Application descriptor module versions updated successfully!")
  if updated_modules:
    print("Modules version updated:")
    print("\n".join(updated_modules))
  else:
    print("No updates were made.")

  return 0


if __name__ == "__main__":
  raise SystemExit(main())
