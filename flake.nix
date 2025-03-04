{
	description = "aloshy.🅰🅸 | Nix Devbox";

	inputs = {
		nixpkgs.url = "github:nixos/nixpkgs";

		snowfall-lib = {
			url = "github:snowfallorg/lib";
			inputs.nixpkgs.follows = "nixpkgs";
		};

    snowfall-flake = {
			url = "github:snowfallorg/flake";
			inputs.nixpkgs.follows = "nixpkgs";
		};

		dotbox = {
			url = "github:snowfallorg/dotbox";
			inputs.nixpkgs.follows = "nixpkgs";
		};

    devbox = {
      url = "github:jetify-com/devbox";
      inputs.nixpkgs.follows = "nixpkgs";
    };
	};

	outputs = inputs:
		inputs.snowfall-lib.mkFlake {
			inherit inputs;
			src = ./.;

			overlays = with inputs; [
				# Use the overlay provided by this flake.
				dotbox.overlay

				# There is also a named overlay, though the output is the same.
				dotbox.overlays."nixpkgs/snowfallorg"

        # Use the overlay provided by this flake.
				snowfall-flake.overlay

				# There is also a named overlay, though the output is the same.
				snowfall-flake.overlays."package/flake"
			];
		};
}