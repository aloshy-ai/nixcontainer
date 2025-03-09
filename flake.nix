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
        system = pkgs.system;
        n2c = nix2container.packages.${system}.nix2container;

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
          name = "aloshy-ai-devcontainer";
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

          config = {
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
        };
      in {
        # Container image and utilities
        packages = {
          inherit devcontainer;
          copyToDocker = devcontainer.copyToDockerDaemon;
          default = devcontainer;
        };
      };
    };
}
