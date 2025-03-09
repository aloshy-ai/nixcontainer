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
      inherit self;
      inherit inputs;

      outputsBuilder = channels: let
        pkgs = channels.nixpkgs;
        system = pkgs.system;
        n2c = nix2container.packages.${system}.nix2container;

        # Base system layer with minimal tools
        baseLayer = pkgs.buildEnv {
          name = "base-layer";
          paths = with pkgs; [
            coreutils
            bash
            git
          ];
        };

        # Development tools layer
        devLayer = pkgs.buildEnv {
          name = "dev-layer";
          paths = with pkgs; [
            nix
            nixpkgs-fmt
            docker
          ];
        };

        # Create vscode user and group
        setupScript = pkgs.writeScriptBin "setup.sh" ''
          #!/bin/sh
          groupadd -g 1000 vscode
          useradd -u 1000 -g vscode -m -s /bin/bash vscode
          mkdir -p /workspace && chown vscode:vscode /workspace
          mkdir -p /home/vscode/.vscode-server && chown vscode:vscode /home/vscode/.vscode-server
        '';

        # Root filesystem setup
        rootFs = pkgs.buildEnv {
          name = "root";
          paths = [
            baseLayer
            devLayer
            setupScript
          ];
        };

        # DevContainer image
        devcontainer = n2c.buildImage {
          name = "aloshy-ai-devcontainer";
          tag = "latest";

          # Layer optimization
          copyToRoot = rootFs;

          config = {
            Cmd = ["/bin/setup.sh"];
            Env = [
              "NIX_CONFIG=experimental-features = nix-command flakes"
              "PATH=/bin:/usr/bin:/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/per-user/vscode/profile/bin"
              "USER=vscode"
              "HOME=/home/vscode"
            ];
            WorkingDir = "/workspace";
            User = "vscode";
            Volumes = {
              "/workspace" = {};
              "/nix/store" = {};
              "/nix/var/nix/db" = {};
              "/nix/var/nix/profiles/per-user/vscode" = {};
              "/home/vscode/.vscode-server" = {};
            };
            Labels = {
              "devcontainer.metadata" = builtins.toJSON {
                remoteUser = "vscode";
                remoteWorkspaceFolder = "/workspace";
                customizations = {
                  vscode = {
                    extensions = [
                      "bbenoist.Nix"
                      "mkhl.direnv"
                      "ms-vscode-remote.remote-containers"
                    ];
                  };
                };
              };
            };
          };
        };
      in {
        # Development shell for local development
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            docker
          ];
        };

        # Container image and utilities
        packages = {
          inherit devcontainer;
          copyToDocker = devcontainer.copyToDockerDaemon;
        };
      };
    };
}
