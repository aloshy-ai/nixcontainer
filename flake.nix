{
  description = "aloshy.🅰🅸 | Devbox";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-utils-plus.url = "github:gytis-ivaskevicius/flake-utils-plus";
    nix2container.url = "github:nlewo/nix2container";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-utils-plus,
    nix2container,
    home-manager,
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
            "PATH=/bin:/usr/bin:/nix/var/nix/profiles/default/bin:/home/vscode/.nix-profile/bin"
            "USER=vscode"
            "HOME=/home/vscode"
            "SHELL=/bin/bash"
            "LANG=en_US.UTF-8"
            "NIX_PATH=/nix/var/nix/profiles/per-user/vscode/channels"
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
            iana-etc
          ];
        };

        # System files layer with pre-created users
        systemFilesLayer = n2c.buildLayer {
          deps = [];
          contents = [
            (pkgs.writeTextDir "etc/passwd" ''
              root:x:0:0:System administrator:/root:/bin/bash
              nobody:x:65534:65534:Nobody:/:/bin/false
              vscode:x:1000:1000:VSCode User:/home/vscode:/bin/bash
            '')
            (pkgs.writeTextDir "etc/group" ''
              root:x:0:
              nobody:x:65534:
              vscode:x:1000:
            '')
            (pkgs.writeTextDir "etc/shadow" ''
              root:!:1::::::
              nobody:!:1::::::
              vscode:!:1::::::
            '')
            (pkgs.writeTextDir "home/vscode/.bashrc" '''')
          ];
        };

        # VSCode server layer (required for DevContainer)
        vscodeLayer = n2c.buildLayer {
          deps = with pkgs; [
            nodejs # Required for VSCode server
            home-manager
          ];
        };

        # Home manager configuration
        homeConfig = {
          home.stateVersion = "23.11";
          programs.vscode = {
            enable = true;
            mutableExtensionsDir = true;
            profiles.default.userSettings = {
              "editor.fontFamily" = "'JetBrainsMono Nerd Font Mono', 'Droid Sans Mono', 'monospace', monospace";
              "editor.fontLigatures" = true;
              "editor.fontSize" = 14;
              "editor.minimap.enabled" = false;
              "editor.stickyScroll.enabled" = false;
              "files.autoSave" = "afterDelay";
              "terminal.integrated.fontLigatures.enabled" = true;
              "workbench.colorTheme" = "GitHub Dark";
              "workbench.activityBar.orientation" = "vertical";
              "git.confirmSync" = false;
              "git.autofetch" = true;
            };
            profiles.default.extensions = with pkgs.vscode-marketplace; [
              zongou.vs-seti-jetbrainsmononerdfontmono
              ms-vscode-remote.remote-containers
              github.vscode-pull-request-github
              github.vscode-github-actions
              fuadpashayev.bottom-terminal
              ms-azuretools.vscode-docker
              github.github-vscode-theme
              esbenp.prettier-vscode
              kamadorueda.alejandra
              fsevenm.run-it-on
              jetpack-io.devbox
              github.codespaces
              github.remotehub
              github.copilot
              bbenoist.nix
              mkhl.direnv
            ];
          };
        };

        # Setup script for minimal environment
        setupScript = pkgs.writeScriptBin "setup.sh" ''
                    #!/bin/sh
                    set -e

                    # Setup workspace and vscode directories
                    mkdir -p /workspace && chown 1000:1000 /workspace
                    mkdir -p /home/vscode/.vscode-server && chown 1000:1000 /home/vscode/.vscode-server

                    # Setup home-manager for vscode user
                    if [ ! -d "/home/vscode/.config/home-manager" ]; then
                      mkdir -p /home/vscode/.config/home-manager
                      cat > /home/vscode/.config/home-manager/home.nix <<EOF
                      ${builtins.toJSON homeConfig}
          EOF
                      chown -R 1000:1000 /home/vscode/.config
                      su vscode -c "home-manager switch"
                    fi
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
