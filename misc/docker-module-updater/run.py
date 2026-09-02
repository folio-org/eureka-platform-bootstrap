#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import OrderedDict
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent.parent
DEFAULT_DESCRIPTOR_PATH = PROJECT_ROOT / "descriptors" / "app-platform-minimal" / "descriptor.json"
MODULE_COMPOSE_PATH = PROJECT_ROOT / "docker" / "docker-compose.minimal.module.yml"
SIDECAR_COMPOSE_PATH = PROJECT_ROOT / "docker" / "docker-compose.minimal.sidecar.yml"
ENV_LOCAL_PATH = PROJECT_ROOT / "docker" / ".env.local"

SERVICE_LINE_PATTERN = re.compile(r"^\s{2}([a-z0-9-]+):\s*$")
EXPORT_PATTERN = re.compile(r"^export\s+([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
ENV_ASSIGNMENT_PATTERN = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")

GENERATED_BLOCK_BEGIN = "# BEGIN generated module runtime metadata"
GENERATED_BLOCK_END = "# END generated module runtime metadata"
GENERATED_BLOCK_NOTE = "# Managed by misc/docker-module-updater/run.py — do not edit by hand."
# Header comments emitted by earlier generations; removed on regeneration so the
# metadata collapses into a single managed block.
LEGACY_GENERATED_HEADERS = (
  "# generated module versions",
  "# generated module images and versions",
)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
  parser = argparse.ArgumentParser(
    description="Sync descriptor-driven module metadata and resolve app services.",
  )
  parser.add_argument(
    "--app",
    default=str(DEFAULT_DESCRIPTOR_PATH),
    help="Path to the application descriptor to process.",
  )
  parser.add_argument(
    "--services",
    action="store_true",
    help="Print a validated descriptor-ordered service list without mutating files.",
  )
  parser.add_argument(
    "--module-env",
    action="store_true",
    help="Print descriptor-derived MOD_* exports without mutating files.",
  )
  return parser.parse_args(argv)


def read_json(file_path: Path) -> OrderedDict:
  with file_path.open("r", encoding="utf-8") as stream:
    return json.load(stream, object_pairs_hook=OrderedDict)


def read_file_lines(file_path: Path) -> list[str]:
  try:
    with file_path.open("r", encoding="utf-8") as stream:
      return [line.rstrip("\n") for line in stream.readlines()]
  except FileNotFoundError:
    return []


def write_file_lines(file_path: Path, lines: list[str]) -> None:
  with file_path.open("w", newline="\n", encoding="utf-8") as outfile:
    for line in lines:
      outfile.write(line)
      outfile.write("\n")


def write_json(file_path: Path, content: OrderedDict) -> None:
  with file_path.open("w", newline="\n", encoding="utf-8") as outfile:
    outfile.write(json.dumps(content, indent=2))
    outfile.write("\n")


def resolve_descriptor_path(app_path: str) -> Path:
  descriptor_path = Path(app_path).expanduser()
  if not descriptor_path.is_absolute():
    descriptor_path = (Path.cwd() / descriptor_path).resolve()
  else:
    descriptor_path = descriptor_path.resolve()

  if not descriptor_path.is_file():
    raise ValueError(f"Descriptor file not found: {descriptor_path}")
  return descriptor_path


def get_discovery_path(descriptor_path: Path) -> Path:
  return descriptor_path.with_name("discovery.json")


def get_module_versions(application_descriptor: OrderedDict) -> OrderedDict[str, str]:
  module_versions: OrderedDict[str, str] = OrderedDict()
  for module in application_descriptor.get("modules", []):
    module_name = module.get("name")
    module_version = module.get("version")

    if not module_name:
      raise ValueError("Descriptor contains a module with a missing name")
    if module_name in module_versions:
      raise ValueError(f"Descriptor contains duplicate module name: {module_name}")
    if not module_version:
      raise ValueError(f"Descriptor module {module_name} is missing version")

    module_versions[module_name] = module_version

  return module_versions


def parse_compose_services(compose_path: Path) -> set[str]:
  services: set[str] = set()
  in_services = False

  for line in read_file_lines(compose_path):
    if line == "services:":
      in_services = True
      continue

    if not in_services:
      continue

    match = SERVICE_LINE_PATTERN.match(line)
    if match:
      services.add(match.group(1))

  return services


def get_service_list(
  module_versions: OrderedDict[str, str],
  module_services: set[str],
  sidecar_services: set[str],
) -> list[str]:
  resolved_services: list[str] = []
  missing_services: list[str] = []

  for module_name in module_versions:
    sidecar_name = module_name.replace("mod-", "sc-", 1)

    if module_name not in module_services:
      missing_services.append(module_name)
    if sidecar_name not in sidecar_services:
      missing_services.append(sidecar_name)

    if module_name in module_services and sidecar_name in sidecar_services:
      resolved_services.extend([module_name, sidecar_name])

  if missing_services:
    missing_display = ", ".join(missing_services)
    raise ValueError(f"Descriptor modules are missing compose service pairs: {missing_display}")

  return resolved_services


def build_module_image(module_name: str, module_version: str) -> str:
  repository = "folioci" if "SNAPSHOT" in module_version else "folioorg"
  return f"{repository}/{module_name}:{module_version}"


def update_module_discovery(discovery_path: Path, module_versions: OrderedDict[str, str]) -> None:
  discovery = []
  for module_name, module_version in module_versions.items():
    discovery.append(OrderedDict({
      "id": f"{module_name}-{module_version}",
      "name": module_name,
      "version": module_version,
      "location": f"http://{module_name.replace('mod-', 'sc-', 1)}:8081",
    }))

  result_object = OrderedDict({"discovery": discovery})
  write_json(discovery_path, result_object)


def owned_generated_var_names(
  module_versions: OrderedDict[str, str],
  known_module_services: set[str],
) -> set[str]:
  """Variable names this generator owns and may rewrite or drop.

  Built from both the descriptor modules and the compose-declared module
  services, so that generated vars for a module dropped from the descriptor are
  still recognised (and therefore removed) on regeneration. Prefixes are MOD_*,
  so hand-authored vars such as FOLIO_KEYCLOAK_IMAGE or MGR_*_IMAGE are never matched.
  """
  owned: set[str] = set()
  for name in set(known_module_services) | set(module_versions):
    prefix = name.upper().replace("-", "_")
    owned.update({f"{prefix}_IMAGE", f"{prefix}_VERSION", f"{prefix}_REPOSITORY"})
  return owned


def cleanup_module_runtime_metadata(
  env_local_path: Path,
  module_versions: OrderedDict[str, str],
  known_module_services: set[str],
) -> None:
  if not env_local_path.exists():
    return

  lines = read_file_lines(env_local_path)
  owned_var_names = owned_generated_var_names(module_versions, known_module_services)

  # Strip the previous managed block, legacy generated regions, and obsolete
  # MOD_*_REPOSITORY values. Standalone module IMAGE/VERSION assignments outside
  # those regions are now treated as hand-authored local overrides;
  # descriptor-derived defaults are exported in-memory by the bootstrap instead
  # of persisted in .env.local.
  preserved: list[str] = []
  in_managed_block = False
  in_legacy_generated_region = False
  for line in lines:
    if line == GENERATED_BLOCK_BEGIN:
      in_managed_block = True
      continue
    if in_managed_block:
      if line == GENERATED_BLOCK_END:
        in_managed_block = False
      continue
    if line in LEGACY_GENERATED_HEADERS:
      in_legacy_generated_region = True
      continue
    match = ENV_ASSIGNMENT_PATTERN.match(line)
    if in_legacy_generated_region and match and match.group(1) in owned_var_names:
      continue
    in_legacy_generated_region = False
    if match and match.group(1).endswith("_REPOSITORY") and match.group(1) in owned_var_names:
      continue
    preserved.append(line)

  while preserved and preserved[-1] == "":
    preserved.pop()

  write_file_lines(env_local_path, preserved)


def print_module_env_exports(module_versions: OrderedDict[str, str]) -> None:
  for module_name, module_version in module_versions.items():
    prefix = module_name.upper().replace("-", "_")
    print(f"export {prefix}_IMAGE={build_module_image(module_name, module_version)}")
    print(f"export {prefix}_VERSION={module_version}")


def main(argv: list[str] | None = None) -> int:
  args = parse_args(argv)

  try:
    descriptor_path = resolve_descriptor_path(args.app)
    application_descriptor = read_json(descriptor_path)
    module_versions = get_module_versions(application_descriptor)
    module_services = parse_compose_services(MODULE_COMPOSE_PATH)
    sidecar_services = parse_compose_services(SIDECAR_COMPOSE_PATH)
    service_list = get_service_list(module_versions, module_services, sidecar_services)
  except (OSError, json.JSONDecodeError, ValueError) as error:
    print(str(error), file=sys.stderr)
    return 1

  if args.services:
    print(" ".join(service_list))
    return 0
  if args.module_env:
    print_module_env_exports(module_versions)
    return 0

  try:
    update_module_discovery(get_discovery_path(descriptor_path), module_versions)
    cleanup_module_runtime_metadata(ENV_LOCAL_PATH, module_versions, module_services)
  except OSError as error:
    print(str(error), file=sys.stderr)
    return 1

  return 0


if __name__ == "__main__":
  raise SystemExit(main())
