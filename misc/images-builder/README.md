Run the following command to build the images for your current platform from the `eureka-platform-bootstrap` folder:

```bash
./misc/image-builder/build.sh
```

**Purpose:**
This script is designed to create Docker images that are compatible with your current platform. The default base image provided by Folio may not support your platform, necessitating this custom build process.

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

**Benefits:**
- **Solves Platform Mismatch Issues:** By building images locally on your current platform, the script resolves platform version mismatches that may arise due to incompatibilities with pre-built images.
- **Local Image Building:** The script builds all images locally, which helps in scenarios where images are not available in the registry, facilitating problematic deployments.
- **Snapshot Versions:** All modules with snapshot versions are built from the master branch. Be aware that the actual application version may not correspond to the versions specified in the module descriptors. This could lead to mismatches between the interfaces described in the module descriptor and the actual behavior of the module.

This ensures that all necessary images are built and compatible with your current platform, facilitating deployment in environments where pre-built images may not be available.
