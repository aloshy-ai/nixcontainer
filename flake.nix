{
  description = "aloshy.🅰🅸 | Devbox";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-utils-plus.url = "github:gytis-ivaskevicius/flake-utils-plus";
    nix2container.url = "github:nlewo/nix2container";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-utils-plus,
    nix2container,
    ...
  }:
    flake-utils-plus.lib.mkFlake {
      inherit self inputs;

      outputsBuilder = channels: let
        pkgs = channels.nixpkgs;
        lib = pkgs.lib;
        system = pkgs.system;
        n2c = nix2container.packages.${system}.nix2container;

        # Container configuration
        containerConfig = {
          Cmd = ["/bin/setup.sh"];
          Env = [
            "PATH=/bin:/usr/bin:/nix/var/nix/profiles/default/bin"
            "USER=vscode"
            "HOME=/home/vscode"
            "SHELL=/bin/bash"
            "LANG=en_US.UTF-8"
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
            bash
            coreutils
            git
          ];
        };

        # VSCode server layer (required for DevContainer)
        vscodeLayer = n2c.buildLayer {
          deps = with pkgs; [
            nodejs # Required for VSCode server
          ];
        };

        # Setup script for minimal environment
        setupScript = pkgs.writeScriptBin "setup.sh" ''
          #!/bin/sh
          set -e

          # Create user and group
          groupadd -g 1000 vscode || echo "Group already exists"
          useradd -u 1000 -g vscode -m -s /bin/bash vscode || echo "User already exists"

          # Setup workspace and vscode directories
          mkdir -p /workspace && chown vscode:vscode /workspace
          mkdir -p /home/vscode/.vscode-server && chown vscode:vscode /home/vscode/.vscode-server
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

        # Helper function to check if a value exists in a list
        contains = list: value: builtins.elem value list;

        # Container image and utilities
        packages = {
          inherit devcontainer pushToGhcr;
          copyToDocker = devcontainer.copyToDockerDaemon;
          default = devcontainer;
        };
      in {
        # Container image and utilities
        packages = {
          inherit devcontainer pushToGhcr;
          copyToDocker = devcontainer.copyToDockerDaemon;
          default = devcontainer;
        };
      };
    };
}
