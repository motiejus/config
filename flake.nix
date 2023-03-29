{
  description = "flake for hel1-a";

  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-22.11";
    };
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations = {
      hel1-a = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
        ];
      };
    };
  };
}
