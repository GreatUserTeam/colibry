# Shell module of Colibry.
# Bash is replaced by Zsh as the default interactive and system shell.
# The prompt imitates macOS Terminal: minimal, clean, no clutter.
{ config, pkgs, lib, ... }:

{
  # Zsh is installed and set as the default shell for all users.
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestions.enable = true; # Fish-style gray suggestions while typing.
    syntaxHighlighting.enable = true; # Commands are colored while typing.
    histSize = 50000;
    histFile = "$HOME/.local/share/zsh/history";

    # Interactive shell options: colibry users should never be scared by the terminal.
    interactiveShellInit = ''
      # Prompt looks like macOS: "user@host folder %" in green/blue/white.
      autoload -Uz vcs_info
      precmd_vcs_info() { vcs_info }
      precmd_functions+=( precmd_vcs_info )
      zstyle ':vcs_info:git:*' formats ' %b'
      setopt PROMPT_SUBST
      PROMPT='%F{green}%n@%m%f %F{blue}%~%f%F{yellow}$vcs_info_msg_0_%f %# '

      # Auto-correct small typos in commands ("did you mean...").
      setopt CORRECT

      # Tab-completion menu behaves like a friendly list, not a wall of text.
      zstyle ':completion:*' menu select
      zstyle ':completion:*' list-colors "''${(s.:.)LS_COLORS}"

      # Never beep.
      setopt NO_BEEP

      # cd into directories by typing their name alone.
      setopt AUTO_CD

      # zoxide: "z <fragment>" jumps to the most used matching directory.
      eval "$(${pkgs.zoxide}/bin/zoxide init zsh)"
    '';
  };

  # /bin/sh stays POSIX bash for compatibility; users only ever see zsh.
  users.defaultUserShell = pkgs.zsh;

  # The classic GNU commands are shadowed by Rust replacements: the
  # original binaries stay installed for system scripts, but the
  # interactive user only ever meets the modern tool.
  environment.shellAliases = {
    # find -> fd (Rust).
    find = "fd";
    # grep -> ripgrep (Rust).
    grep = "rg";
    # ls -> eza (Rust).
    ls = "eza --group-directories-first";
    ll = "eza --long --group-directories-first";
    tree = "eza --tree";
    # cat -> bat (Rust), plain output like the classic tool.
    cat = "bat --style=plain";
    # sed -> sd (Rust) for interactive editing; scripts keep GNU sed.
    sed = "sd";
    # du -> dust, df -> duf (Rust).
    du = "dust";
    df = "duf";
    # ps/top -> procs (Rust).
    ps = "procs";
    top = "procs";
    # diff -> difftastic (Rust) for interactive compares.
    diff = "difft";
    # vim is gone entirely: nano is the editor, plain and simple.
    vim = "nano";
    vi  = "nano";
    # cp gets a progress bar via rsync.
    cp = "rsync -ah --info=progress2";
  };
}
