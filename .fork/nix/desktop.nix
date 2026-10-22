{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  copyDesktopItems,
  makeDesktopItem,
  makeWrapper,
  wrapGAppsHook3,
  addDriverRunpath,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  desktop-file-utils,
  expat,
  gdk-pixbuf,
  glib,
  gsettings-desktop-schemas,
  gtk3,
  gtk4,
  libdrm,
  libgbm,
  libGL,
  libnotify,
  libpulseaudio,
  libsecret,
  libva,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libxshmfence,
  nspr,
  nss,
  pango,
  pciutils,
  pipewire,
  speechd-minimal,
  systemdLibs,
  vulkan-loader,
  xdg-utils,
  sable-unwrapped,
  sable-electron-app,
}:

let
  # Must match electron/package.json; nixpkgs has no Electron this new.
  electronVersion = "45.0.0";

  # dlopen'd at runtime, so autoPatchelf cannot see them.
  runtimeLibs = [
    gtk4
    libGL
    libnotify
    libpulseaudio
    libsecret
    libva
    libx11
    libxkbcommon
    libxshmfence
    pciutils
    pipewire
    speechd-minimal
    systemdLibs
    vulkan-loader
  ];

  electron = stdenv.mkDerivation {
    pname = "electron-bin";
    version = electronVersion;

    src = fetchurl {
      url = "https://github.com/electron/electron/releases/download/v${electronVersion}/electron-v${electronVersion}-linux-x64.zip";
      hash = "sha256-IvahC9P3/vmH3bs3nTN1zmZK0MmKmlD4DInxcYoMPjo=";
    };

    nativeBuildInputs = [
      unzip
      autoPatchelfHook
    ];

    buildInputs = [
      alsa-lib
      at-spi2-atk
      at-spi2-core
      atk
      cairo
      cups
      dbus
      expat
      gdk-pixbuf
      glib
      gtk3
      libdrm
      libgbm
      libx11
      libxcb
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxkbcommon
      libxrandr
      nspr
      nss
      pango
      stdenv.cc.cc.lib
      systemdLibs
    ];

    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/libexec/electron
      cp -r . $out/libexec/electron
      rm -f $out/libexec/electron/env-vars
      # The bundled Khronos loader does not find NixOS's ICDs.
      ln -sf ${lib.getLib vulkan-loader}/lib/libvulkan.so.1 $out/libexec/electron/libvulkan.so.1
      runHook postInstall
    '';

    # chrome-sandbox cannot be setuid in the store; Chromium uses its user-namespace sandbox instead.
    # RUNPATH, not wrapper env: the app's moe.sable.next-handler.desktop execs this ELF directly.
    # autoPatchelf first, else its --set-rpath drops the extra entries.
    dontAutoPatchelf = true;
    postFixup = ''
      autoPatchelf $out
      patchelf --add-rpath "${lib.makeLibraryPath runtimeLibs}:${addDriverRunpath.driverLink}/lib" \
        $out/libexec/electron/electron
    '';

    meta = {
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      license = lib.licenses.mit;
      platforms = [ "x86_64-linux" ];
    };
  };
in
stdenv.mkDerivation {
  pname = "sable-desktop";
  inherit (sable-unwrapped) version;

  dontUnpack = true;

  nativeBuildInputs = [
    copyDesktopItems
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    glib
    gsettings-desktop-schemas
    gtk3
  ];

  dontWrapGApps = true;

  # main.ts resolves ../dist and ../src-tauri/icons from the app dir; copied so a realpath'd app dir still finds them.
  installPhase = ''
    runHook preInstall
    share=$out/share/sable-desktop
    mkdir -p $share
    cp -r ${sable-electron-app}/app $share/app
    ln -s ${sable-electron-app}/src-tauri $share/src-tauri
    ln -s ${sable-unwrapped} $share/dist
    install -Dm644 ${sable-electron-app}/src-tauri/icons/128x128.png \
      $out/share/icons/hicolor/128x128/apps/sable-next-msc2815.png
    runHook postInstall
  '';

  preFixup = ''
    makeWrapper ${electron}/libexec/electron/electron $out/bin/sable-next-msc2815 \
      "''${gappsWrapperArgs[@]}" \
      --unset ELECTRON_RUN_AS_NODE \
      --prefix PATH : "${lib.makeBinPath [ xdg-utils desktop-file-utils ]}" \
      --add-flags "$out/share/sable-desktop/app --ozone-platform-hint=auto --enable-features=WaylandWindowDecorations"
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "sable-next-msc2815";
      desktopName = "Sable Next (MSC2815)";
      comment = "Matrix client";
      exec = "sable-next-msc2815 %U";
      icon = "sable-next-msc2815";
      mimeTypes = [ "x-scheme-handler/moe.sable.next" ];
      categories = [
        "Network"
        "InstantMessaging"
        "Chat"
      ];
    })
  ];

  passthru = { inherit electron; };

  meta = sable-unwrapped.meta // {
    description = "Sable Next with MSC2815 (Electron ${electronVersion})";
    platforms = [ "x86_64-linux" ];
    mainProgram = "sable-next-msc2815";
  };
}
