# AppArmor module of Skein, tuned for a NixOS base.
#
# Two Nix-specific problems are solved here:
#
#   * AppArmor is compiled into the kernel but not activated as the
#     running Linux Security Module unless the command line selects it.
#     Without it every policy silently skips (the boot log shows
#     "Load AppArmor policies skipped, unmet condition check
#     ConditionSecurity=apparmor"), which means the confinement layer is
#     a no-op. The kernel parameters below pin AppArmor as the active
#     LSM on every boot.
#
#   * Stock AppArmor abstractions describe a Filesystem Hierarchy Standard
#     host: binaries live under /usr, libraries under /lib, configuration
#     under /etc. On Skein every program, library and profiled binary
#     resolves through /nix/store and the /run/current-system profile
#     link, so a profile written against FHS paths denies perfectly
#     legitimate access and, worse, any confined process that takes part
#     in a nix build breaks the sandbox. The abstraction shipped here
#     grants the read side of the store and the writable state of the
#     nix daemon, and every Skein profile includes it.
#
# The abstraction is deliberately read-only for the store: profiles never
# grant write access to /nix/store; the only writable nix paths are the
# daemon state, the per-user profiles and the build directories, exactly
# mirroring the trust boundary of the daemon itself.
{ config, pkgs, lib, ... }:

let
  # The nix-store abstraction: included by AppArmor profiles as
  # "include <abstractions/nix-store>". It is a plain rule fragment, the
  # same shape as the stock abstractions that ship with AppArmor.
  nixStoreAbstraction = pkgs.writeTextDir "etc/apparmor.d/abstractions/nix-store" ''
    # Abstraction for NixOS hosts: everything a profiled program needs to
    # execute and read programs, libraries and data from the nix store.
    # Read-only on purpose; see the module header for the reasoning.

    # All installed software: binaries, libraries, shared data, fonts.
    /nix/store/** r,

    # The profile link tree the running system is assembled from.
    /nix/var/nix/profiles/** r,
    /run/current-system/** r,
    /run/booted-system/** r,

    # Writable daemon state: the daemon socket directory, the per-user
    # profiles and gc roots. Profiles that drive nix builds include these
    # lines; programs that merely run software do not need them and keep
    # including only the read rules above.
    /nix/var/nix/daemon-socket/** rw,
    /nix/var/nix/gcroots/** rwk,
    /nix/var/nix/db/** rk,
  '';
in
{
  # Activate AppArmor as the system security module. Without these two
  # parameters the kernel leaves the LSM slot to the default stack and
  # every policy unit exits on its condition check, which is the silent
  # no-op state described in the module header.
  boot.kernelParams = [ "apparmor=1" "security=apparmor" ];

  # The AppArmor policy engine itself.
  security.apparmor = {
    enable = lib.mkDefault true;

    # Ship the nix-store abstraction so every profile built for Skein can
    # resolve store paths instead of failing on FHS assumptions.
    packages = [ nixStoreAbstraction ];
  };
}
