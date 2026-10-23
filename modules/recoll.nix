# Recoll: the file indexing and full-text search layer of Spark, in the
# role macOS assigns to Spotlight. Two pieces make the role real:
#  * the recoll package (GUI + indexer), available to every user;
#  * a per-user systemd service running "recollindex -m", the continuous
#    monitor mode: it walks the user's topdirs once, then keeps watching
#    them and reindexes changed files in place - exactly like Spotlight's
#    indexing daemon. The service is a USER unit: it starts with the
#    graphical session, after the (encrypted, systemd-homed) home has been
#    mounted and unlocked, so the index never touches locked data.
{ config, pkgs, lib, ... }:

{
  # The Recoll GUI and indexer. Xapian (the search engine) and the common
  # format handlers (text, PDF, office documents, images metadata) are
  # part of the package and work out of the box.
  environment.systemPackages = [ pkgs.recoll ];

  # The continuous indexer of every user session. Nice level and idle I/O
  # scheduling keep it invisible during work; the restart policy recovers
  # it from crashes without user attention.
  systemd.user.services.recoll-index = {
    description = "Recoll continuous file indexer";
    documentation = [ "man:recollindex(1)" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.recoll}/bin/recollindex -m";
      Restart = "on-failure";
      RestartSec = 30;
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  # Default configuration for users created after this profile is
  # installed (systemd-homed picks /etc/skel up when the home is created).
  # It indexes the whole home directory and skips the heavy, low-value
  # trees (build caches, VCS internals, package caches), which is what a
  # desktop search index should contain. Users without this file get the
  # same behavior on first run: recollindex creates the configuration with
  # the home directory as the default topdir.
  environment.etc."skel/.recoll/recoll.conf".text = ''
    # Top-level directories to index: the user's home.
    topdirs = ~/

    # Names to skip anywhere below a topdir: build and package caches and
    # VCS internals carry no searchable user content but churn constantly.
    skippedNames = node_modules .cache .npm .cargo .rustup target .git .svn .hg __pycache__ .local/share/Trash

    # Follow symbolic links pointing inside the indexed area.
    followLinks = 1
  '';
}
