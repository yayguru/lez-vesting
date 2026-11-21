{
  description = "Vesting module (RFP-017 prototype): LEZ 0.4 token vesting for Logos Basecamp";

  nixConfig = {
    extra-substituters = [ "https://cache.nix.logos.co/public" ];
    extra-trusted-public-keys = [ "public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=" ];
  };

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.3.1";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
      # The module drives the `vesting` CLI (built with cargo from ../../cli against the LEZ
      # 0.4.0-rc3 wallet) and ships it next to the plugin. bin/ holds the per-platform binary.
      postInstall = ''
        mkdir -p $out/lib
        # Windows builds ship only a native vesting.exe (if present); the Linux CLI is
        # never bundled there - on Windows the module defaults to the WSL backend.
        case "$out" in
          *mingw32*) cands="${./bin}/vesting.exe" ;;
          *) cands="${./bin}/vesting" ;;
        esac
        for f in $cands; do
          [ -f "$f" ] && install -m755 "$f" $out/lib/
        done
        true
      '';
    };
}
