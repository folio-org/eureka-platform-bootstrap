#!/usr/bin/env python3
import re

import os
import sys
import json
from collections import OrderedDict


def setScriptDirectory():
  try:
    # Get the directory name of the script
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # Change the current working directory to the script directory
    os.chdir(script_dir)
  except Exception as e:
    print(f"Failed to change directory: {e}")
    sys.exit(1)


def readJson(file):
  with open(file, "r") as stream:
    return json.loads(stream.read(), object_pairs_hook=OrderedDict)


def readFileLines(file):
  try:
    with open(file, "r") as stream:
      return [line.rstrip() for line in stream.readlines()]
  except FileNotFoundError:
    return []


def writeFileLines(file, lines):
  with open(file, "w", newline='\n', encoding="utf-8") as outfile:
    for line in lines:
      outfile.write(line)
      outfile.write("\n")


def writeJson(file, content):
  with open(file, "w", newline='\n', encoding="utf-8") as outfile:
    outfile.write(json.dumps(content, indent=2))
    outfile.write("\n")


def getModuleVersions(applicationDescriptor):
  moduleVersions = OrderedDict({})
  for module in applicationDescriptor['modules']:
    moduleVersions[module['name']] = module.get('version')
  return moduleVersions


def updateModuleDiscovery(moduleVersions):
  discovery = []
  for moduleName, moduleVersion in moduleVersions.items():
    discovery.append(OrderedDict({
      "id": moduleName + "-" + moduleVersion,
      "name": moduleName,
      "version": moduleVersion,
      "location": "http://" + moduleName.replace("mod-", "sc-") + ":8081"
    }))
  discoveryFilePath = "../../descriptors/app-platform-minimal/discovery.json"
  resultObject = OrderedDict({"discovery": discovery})
  writeJson(discoveryFilePath, resultObject)


def updateModuleVersions(moduleVersions):
  pattern = re.compile(r"^(\s{4}container_name:\s.*)(mod-.+)$")
  moduleDockerComposeFileLines = readFileLines("../../docker/docker-compose.minimal.module.yml")
  moduleNames = []
  for line in moduleDockerComposeFileLines:
    match = pattern.match(line)
    if match:
      moduleNames.append(match.group(2))

  envVariableDict = OrderedDict({})
  pattern = re.compile(r"^export (.+)=(.+)$")
  localConfigurationLines = readFileLines("../../docker/.env.local")
  for idx, line in enumerate(localConfigurationLines):
    match = pattern.match(line)
    if match:
      name = match.group(1)
      value = match.group(2)
      envVariableDict[name] = {"value": value, "idx": idx}

  visited = False
  for module in moduleNames:
    newModuleVersion = moduleVersions.get(module)
    if newModuleVersion is None:
      continue

    prefix = module.upper().replace("-", "_")
    versionEnvVariable = prefix + "_VERSION"
    definedModuleVersion = envVariableDict.get(versionEnvVariable)
    if definedModuleVersion is not None:
      localConfigurationLines[definedModuleVersion["idx"]] = "export " + versionEnvVariable + "=" + newModuleVersion
    else:
      if not visited:
        localConfigurationLines.append("")
        localConfigurationLines.append("# generated module versions and repositories")
        visited = True
      localConfigurationLines.append("export " + versionEnvVariable + "=" + newModuleVersion)

    repositoryEnvVariable = prefix + "_REPOSITORY"
    definedModuleRepository = envVariableDict.get(repositoryEnvVariable)
    newRepositoryValue = "folioci/" + module if "SNAPSHOT" in newModuleVersion else "folioorg/" + module
    if definedModuleRepository is not None:
      localConfigurationLines[
        definedModuleRepository["idx"]] = "export " + repositoryEnvVariable + "=" + newRepositoryValue
    else:
      localConfigurationLines.append("export " + repositoryEnvVariable + "=" + newRepositoryValue)

    writeFileLines("../../docker/.env.local", localConfigurationLines)


def main():
  setScriptDirectory()
  applicationDescriptor = readJson("../../descriptors/app-platform-minimal/descriptor.json")
  moduleVersions = getModuleVersions(applicationDescriptor)
  updateModuleDiscovery(moduleVersions)
  updateModuleVersions(moduleVersions)


if __name__ == "__main__":
  main()
