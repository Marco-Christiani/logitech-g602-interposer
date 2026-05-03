# Builds hid-logitech-dj.ko with report 0x80 silenced.
#
# The G602 sends HID report 0x80 on every button event. The in-tree driver
# logs hid_err for every report ID it doesn't recognise, producing one kernel
# error per button press. The report is correctly consumed by the daemon via
# hidraw; the kernel driver need not handle it.
#
# The upstream patch (https://www.spinics.net/lists/linux-input/msg98800.html)
# has not been merged as of kernel 6.12. We carry it here as a one-line guard
# on the hid_err call, built as an out-of-tree replacement for the in-tree
# module.
{ lib, stdenv, kernel }:
stdenv.mkDerivation {
  pname = "hid-logitech-dj-patched";
  version = kernel.version;

  src = kernel.src;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  # Kernel modules cannot use position-independent code or the default
  # fortify/format hardening; the kernel Makefile sets its own flags.
  hardeningDisable = [ "pic" "format" ];

  postPatch = ''
    substituteInPlace drivers/hid/hid-logitech-dj.c \
      --replace-fail \
        'hid_err(hdev, "Unexpected input report number %d\n", report);' \
        'if (report != 0x80) hid_err(hdev, "Unexpected input report number %d\n", report);'
  '';

  buildPhase = ''
    runHook preBuild
    # Override the hid subtree Makefile. The kernel out-of-tree build system
    # prefers Kbuild over Makefile when M= is set, so this does not affect
    # any other in-tree build that might reference the original Makefile.
    echo 'obj-m := hid-logitech-dj.o' > drivers/hid/Kbuild
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
      M=$(pwd)/drivers/hid \
      modules
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 drivers/hid/hid-logitech-dj.ko \
      "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/hid/hid-logitech-dj.ko"
    runHook postInstall
  '';

  meta = {
    description = "hid-logitech-dj with G602 report 0x80 silenced";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
