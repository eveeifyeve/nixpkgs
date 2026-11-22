{
  lib,
  fetchFromGitHub,
  makeWrapper,
  open-apple-macros,
  python3,
  rcodesign,
  stdenv,
  swift,
  swiftpm,
}:

let
  # From CoreEQ.xcodeproj/project.pbxproj (MACOSX_DEPLOYMENT_TARGET); the
  # engine calls the macOS 14.2 process-tap APIs unguarded.
  deploymentTarget = "14.2";
in

stdenv.mkDerivation (finalAttrs: {
  pname = "coreeq";
  version = "1.10";

  src = fetchFromGitHub {
    owner = "andreypudov";
    repo = "core-eq";
    tag = "v${finalAttrs.version}";
    hash = "sha256-I5cBxui2XkPOjmqJVCWZXiDfE80f0b1t3RwOMLeIAtI=";
  };

  __structuredAttrs = true;
  strictDeps = true;

  nativeBuildInputs = [
    makeWrapper
    python3
    rcodesign
    swift
    swiftpm
  ];

  # SDK 27's SwiftUI interfaces declare `@State` and friends as macros whose
  # plugin (SwiftUIMacros) ships only with Xcode; open-apple-macros
  # reimplements it. See also the flags in swiftpmFlags.
  swiftpmFlags = [
    "-Xswiftc"
    "-external-plugin-path"
    "-Xswiftc"
    "${open-apple-macros}/lib/swift/host/plugins#${open-apple-macros}/libexec/swift/plugins/OpenAppleMacrosServer"
  ];

  # Adds a Package.swift which replicates from project.pbxproj.
  postPatch = ''
    cp ${./Package.swift} Package.swift
  '';

  dontUseSwiftpmInstall = true;
  installPhase = ''
    runHook preInstall

    local binPath app currentProjectVersion
    binPath="$(swiftpmBinPath)"
    app="$out/Applications/CoreEQ.app"

    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

    install -m 0755 "$binPath/CoreEQ" "$app/Contents/MacOS/CoreEQ"

    # SwiftPM puts the declared resources in its own bundle next to the
    # product; the app loads them through Bundle.main, so flatten them into
    # the bundle the way Xcode does.
    cp -R "$binPath/CoreEQ_CoreEQ.bundle/Contents/Resources/." "$app/Contents/Resources/"

    printf 'APPL????' > "$app/Contents/PkgInfo"

    # The upstream Info.plist uses Xcode build-setting placeholders.
    currentProjectVersion="$(
      sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([0-9]*\);/\1/p' \
        CoreEQ.xcodeproj/project.pbxproj | head -1
    )"
    sed \
      -e "s/\$(EXECUTABLE_NAME)/CoreEQ/g" \
      -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.andreypudov.coreeq/g" \
      -e "s/\$(PRODUCT_NAME)/CoreEQ/g" \
      -e "s/\$(MARKETING_VERSION)/${finalAttrs.version}/g" \
      -e "s/\$(CURRENT_PROJECT_VERSION)/$currentProjectVersion/g" \
      -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/${deploymentTarget}/g" \
      Config/Info.plist > "$app/Contents/Info.plist"

    # The SwiftPM build system cannot compile String Catalogs without Xcode's
    # xcstringstool, so the manifest excludes them and they are compiled here.
    python3 ${./compile-xcstrings.py} \
      CoreEQ/Resources/Localizable.xcstrings en "$app/Contents/Resources"

    # A bin entry so `nix run` and `nix shell` launch the app; wrapping rather
    # than symlinking keeps Bundle.main resolving to the bundle.
    mkdir -p "$out/bin"
    makeWrapper "$app/Contents/MacOS/CoreEQ" "$out/bin/CoreEQ"

    runHook postInstall
  '';

  # Sign the complete app rather than each Mach-O independently, so the
  # bundle's resources are sealed as one valid signature, the way upstream's
  # `CODE_SIGN_IDENTITY=-` (ad-hoc) Xcode build signs it. Upstream sets no
  # entitlements and no hardened runtime.
  postFixup = ''
    ${lib.getExe rcodesign} sign "$out/Applications/CoreEQ.app"
  '';

  meta = {
    description = "System-wide equalizer for macOS";
    homepage = "https://github.com/andreypudov/core-eq";
    changelog = "https://github.com/andreypudov/core-eq/blob/v${finalAttrs.version}/docs/releases/${finalAttrs.version}.org";
    license = lib.licenses.asl20;
    maintainers = [ lib.maintainers.eveeifyeve ];
    mainProgram = "CoreEQ";
    platforms = lib.platforms.darwin;
  };
})
