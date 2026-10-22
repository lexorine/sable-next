{
  stdenv,
  autoPatchelfHook,
  rustPlatform,
  pnpm_12,
  pnpmConfigHook,
  nodejs_26,
  cmake,
  perl,
  libpulseaudio,
  pipewire,
  sable-unwrapped,
}:

let
  pnpm = pnpm_12;
in
stdenv.mkDerivation {
  pname = "sable-electron-app";
  inherit (sable-unwrapped) version src cargoDeps pnpmDeps;

  __structuredAttrs = true;
  strictDeps = true;

  nativeBuildInputs = [
    pnpm
    (pnpmConfigHook.override { inherit pnpm; })
    nodejs_26
    rustPlatform.rust.rustc
    rustPlatform.rust.cargo
    rustPlatform.cargoSetupHook
    cmake
    perl
    autoPatchelfHook
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    libpulseaudio
    pipewire
  ];

  dontUseCmakeConfigure = true;

  env = {
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
  };

  buildPhase = ''
    runHook preBuild
    node electron/build.mjs --release
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/app $out/src-tauri
    cp -r electron/dist electron/package.json $out/app/
    rm -f $out/app/dist/*.map $out/app/dist/venmic-arm64.node
    cp -r src-tauri/icons $out/src-tauri/icons
    runHook postInstall
  '';

  meta = sable-unwrapped.meta // {
    platforms = [ "x86_64-linux" ];
  };
}
