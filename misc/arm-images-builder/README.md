### ARM Images Builder

Run the following command to build the ARM images from the `eureka-platform-bootstrap` folder:

```bash
./misc/arm-image-builder/build.sh
```

**Purpose:**
This script is designed to create Docker images that are compatible with ARM architecture. The default base image provided by Folio does not support ARM architecture, necessitating this custom build process.

**How it Works:**
1. **Base Image Preparation:**
- The script starts by preparing a base Docker image using Eclipse Temurin's JRE 21 for ARM architecture.

2. **Repository Cloning and Dockerfile Modification:**
- It clones the `folio-tools` repository.
- Modifies the Dockerfile to use the new base image.
- Builds the Docker image.

3. **Module Building:**
- The script reads an application descriptor file (`descriptor.json`) to gather a list of modules that need to be built.
- For each module, it:
  - Clones the module's repository.
  - Checks out the appropriate branch or tag.
  - Builds the module using Maven (if applicable).
  - Builds a Docker image for the module.

4. **Additional Repositories:**
- It also builds additional repositories from the master branch.
- Some repositories are built without using Maven.

5. **Error Handling:**
- The script tracks any modules that fail to build and reports them at the end.

This ensures that all necessary images are built and compatible with ARM architecture, facilitating deployment in ARM-based environments.
