# File integrity scanner configuration of Skein (AIDE).
#
# The integrity service itself (initial database build on first boot, the
# daily check and the timer) is defined in modules/security.nix; this
# module owns the AIDE configuration document. AIDE 0.19 stores database
# locations as URLs and rejects a bare filesystem path ("unknown
# URL-type") as well as the legacy database key; the document below uses
# the current database_in/database_out keys with explicit file: URLs, so
# the parser accepts it.
{ config, pkgs, lib, ... }:

{
  environment.etc."aide.conf" = lib.mkForce {
    text = ''
      # Input database for --check; built by skein-aide-init on first boot.
      database_in=file:/var/lib/aide/aide.db
      # Output database for --init; promoted over the input database by
      # the initial-build service.
      database_out=file:/var/lib/aide/aide.db.new
      gzip_dbout=yes
      NORMAL=R+sha512
      /etc NORMAL
      /boot NORMAL
    '';
  };
}
