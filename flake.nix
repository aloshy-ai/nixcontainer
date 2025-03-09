{
  description = "aloshy.🅰🅸 | NixContainer";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-utils-plus.url = "github:gytis-ivaskevicius/flake-utils-plus";
    nix2container.url = "github:nlewo/nix2container";
    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-utils-plus,
    nix2container,
    nix-vscode-extensions,
    ...
  }:
    flake-utils-plus.lib.mkFlake {
      inherit self inputs;

      outputsBuilder = channels: let
        system = channels.nixpkgs.system;
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
          overlays = [
            nix-vscode-extensions.overlays.default
          ];
        };
        lib = pkgs.lib;
        n2c = nix2container.packages.${system}.nix2container;
        vscode-exts = nix-vscode-extensions.packages.${system};

        # Container configuration
        containerConfig = {
          Cmd = ["/bin/setup.sh"];
          Env = [
            "PATH=/bin:/usr/bin:/nix/var/nix/profiles/default/bin"
            "USER=vscode"
            "HOME=/home/vscode"
            "SHELL=/bin/zsh"
            "LANG=C.UTF-8" # Simpler locale setting
            "ZDOTDIR=/home/vscode"
          ];
          WorkingDir = "/workspace";
          User = "vscode";
          Volumes = {
            "/workspace" = {};
            "/home/vscode/.vscode-server" = {};
          };
          Labels = {
            "devcontainer.metadata" = builtins.toJSON {
              remoteUser = "vscode";
              remoteWorkspaceFolder = "/workspace";
            };
          };
        };

        # Essential system layer (minimal base)
        baseSystemLayer = n2c.buildLayer {
          deps = with pkgs; [
            (hiPrio zsh) # Default shell (high priority to ensure it's preferred)
            bash # Provides /bin/sh and /bin/bash
            coreutils # Essential tools
            git # Version control
            direnv # Environment management
            devbox # Development environments
          ];
        };

        # System files layer with pre-created users
        systemFilesLayer = n2c.buildLayer {
          deps = [];
          contents = [
            (pkgs.writeTextDir "etc/passwd" ''
              root:x:0:0:System administrator:/root:/bin/bash
              nobody:x:65534:65534:Nobody:/:/bin/false
              vscode:x:1000:1000:VSCode User:/home/vscode:/bin/zsh
            '')
            (pkgs.writeTextDir "etc/group" ''
              root:x:0:
              nobody:x:65534:
              vscode:x:1000:
              docker:x:999:vscode
              wheel:x:998:vscode
            '')
            (pkgs.writeTextDir "etc/shadow" ''
              root:!:1::::::
              nobody:!:1::::::
              vscode:!:1::::::
            '')
            # Basic profile with direnv hook and auto-allow/reload
            (pkgs.writeTextDir "home/vscode/.profile" ''
              eval "$(direnv hook bash)"
              direnv allow > /dev/null 2>&1 || true
              direnv reload > /dev/null 2>&1 || true
              curl -fsSL https://ascii.aloshy.ai | sh
            '')
          ];
        };

        # VSCode server layer (required for DevContainer)
        vscodeLayer = n2c.buildLayer {
          deps = with pkgs; [
            nodejs-slim # Minimal Node.js for VS Code server
          ];
        };

        # Setup script for minimal environment
        setupScript = pkgs.writeScriptBin "setup.sh" ''
          #!/bin/sh
          set -e

          # Setup workspace and vscode directories with proper permissions
          mkdir -p /workspace /home/vscode/.vscode-server
          chown -R 1000:1000 /workspace /home/vscode

          # Keep container running
          exec sleep infinity
        '';

        # Root filesystem setup
        rootFs = pkgs.buildEnv {
          name = "root";
          paths = [
            setupScript
          ];
          pathsToLink = ["/bin"];
        };

        # DevContainer image with minimal configuration
        devcontainer = n2c.buildImage {
          name = "nixcontainer";
          tag = "latest";

          # Layer optimization
          copyToRoot = rootFs;
          perms = [
            {
              path = "${rootFs}/bin/setup.sh";
              regex = ".*";
              mode = "0755";
            }
          ];
          layers = [
            baseSystemLayer
            systemFilesLayer
            vscodeLayer
          ];

          config = containerConfig;
        };

        # Script to push image to GHCR
        pushToGhcr = pkgs.writeScriptBin "push-to-ghcr" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          # For local development, use GITHUB_TOKEN if set
          # For GitHub Actions, use the automatic token
          TOKEN="''${GITHUB_TOKEN:-''${GITHUB_TOKEN}}"

          # For local development, use GITHUB_USERNAME if set
          # For GitHub Actions, use GITHUB_ACTOR
          USERNAME="''${GITHUB_USERNAME:-$GITHUB_ACTOR}"

          if [ -z "''${TOKEN}" ]; then
            echo "Error: Neither GITHUB_TOKEN nor automatic GitHub Actions token is available"
            echo "Please set GITHUB_TOKEN with a personal access token with 'write:packages' scope"
            exit 1
          fi

          if [ -z "''${USERNAME}" ]; then
            echo "Error: No GitHub username available"
            echo "Please set GITHUB_USERNAME or run in GitHub Actions environment"
            exit 1
          fi

          # Login to GHCR
          echo $TOKEN | ${pkgs.docker}/bin/docker login ghcr.io -u $USERNAME --password-stdin

          # Load the image into Docker
          ${devcontainer.copyToDockerDaemon}/bin/copy-to-docker-daemon

          # Tag the image for GHCR
          ${pkgs.docker}/bin/docker tag nixcontainer:latest ghcr.io/$USERNAME/nixcontainer:latest

          # Push to GHCR
          ${pkgs.docker}/bin/docker push ghcr.io/$USERNAME/nixcontainer:latest

          echo "Successfully pushed image to ghcr.io/$USERNAME/nixcontainer:latest"
        '';

        # Script to load image into Docker
        loadImage = pkgs.writeScriptBin "load-image" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          # Load the image into Docker
          ${devcontainer.copyToDockerDaemon}/bin/copy-to-docker-daemon

          echo "Successfully loaded image as nixcontainer:latest"
        '';

        # Helper function to check if a value exists in a list
        contains = list: value: builtins.elem value list;

        # Container image and utilities
        packages = {
          inherit devcontainer pushToGhcr loadImage;
          copyToDocker = devcontainer.copyToDockerDaemon;
          default = devcontainer;
        };
      in {
        # Container image and utilities
        packages = {
          inherit devcontainer pushToGhcr loadImage;
          copyToDocker = devcontainer.copyToDockerDaemon;
          default = devcontainer;
        };
      };
    };
}
