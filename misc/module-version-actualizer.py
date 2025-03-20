import json
import urllib.request
import os
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
APP_DESCRIPTOR_PATH = os.path.join(SCRIPT_DIR,
                                   "../descriptors/app-platform-minimal/descriptor.json")

use_pre_release = input(
  "Use latest SNAPSHOT versions (if `no` latest release version will be userd)? (y/n): ").strip().lower()
pre_release = "true" if use_pre_release in ("y", "yes") else "false"


def fetch_module_data(module_name):
  url = f"https://folio-registry.dev.folio.org/_/proxy/modules?preRelease={pre_release}&latest=1&filter={module_name}"
  try:
    with urllib.request.urlopen(url) as response:
      module_data = json.load(response)
      if isinstance(module_data, list) and module_data:
        return module_data[0]
  except Exception as e:
    print(f"Error fetching data for module {module_name}: {e}")
  return None


def extract_version(module_id):
  match = re.search(r'-(\d+\.\d+\.\d+(-SNAPSHOT\.\d+)?)$', module_id)
  return match.group(1) if match else module_id.split("-")[-1]


with open(APP_DESCRIPTOR_PATH, "r", encoding="utf-8") as f:
  app_descriptor = json.load(f)

updated_modules = []
for module in app_descriptor.get("modules", []):
  module_name = module.get("name")
  old_version = module.get("version")
  updated_module = fetch_module_data(module_name)
  if updated_module:
    new_version = extract_version(updated_module["id"])
    if old_version != new_version:
      updated_modules.append(f" - {module_name} {old_version} -> {new_version}")
    module["id"] = updated_module["id"]
    module["version"] = new_version
    module[
      "url"] = f"https://folio-registry.dev.folio.org/_/proxy/modules/{updated_module["id"]}"

with open(APP_DESCRIPTOR_PATH, "w", encoding="utf-8") as f:
  json.dump(app_descriptor, f, indent=2, ensure_ascii=False)

print("Application descriptor module versions updated successfully!")
if updated_modules:
  print("Modules version updated:")
  print("\n".join(updated_modules))
else:
  print("No updates were made.")
