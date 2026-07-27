# Use a slim Node.js base image, which gives us `npm`.
FROM node:20-slim

# Set non-interactive frontend to avoid prompts during package installation.
ENV DEBIAN_FRONTEND=noninteractive

# Install base tools and GPG support for external package repositories.
RUN apt-get update && apt-get install -y \
  curl gpg git gosu ca-certificates expect apt-transport-https \
  && rm -rf /var/lib/apt/lists/*

# Add Microsoft's Debian package feed for .NET SDK installation.
RUN mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
  && chmod go+r /etc/apt/keyrings/microsoft.gpg \
  && . /etc/os-release \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/debian/${VERSION_ID}/prod ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/microsoft-prod.list

# Install .NET SDKs used by the mounted workspace projects.
RUN apt-get update && apt-get install -y \
  dotnet-sdk-8.0 \
  dotnet-sdk-10.0 \
  && rm -rf /var/lib/apt/lists/*

# Add certificates
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates
# ARG for the Copilot CLI version - passed from build process
# This ensures cache invalidation when a new version is available
ARG COPILOT_VERSION=latest

# Install the standalone GitHub Copilot CLI via npm.
RUN npm config set cafile /etc/ssl/certs/ca-certificates.crt
RUN npm install -g @github/copilot@${COPILOT_VERSION}

# Set the working directory for the container.
WORKDIR /workspace

# Copy the entrypoint script into the container and make it executable.
COPY entrypoint.sh /usr/local/bin/

# Label for image cleanup
LABEL project="copilot"

# The entrypoint script will handle user creation and command execution.
ENTRYPOINT [ "entrypoint.sh" ]

# The default command to run if none is provided.
CMD [ "copilot", "--banner" ]
