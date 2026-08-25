{
  bash,
  borgbackup,
  bubblewrap,
  closureInfo,
  coreutils,
  lib,
  writeShellApplication,
  readerSnapshotRoot,
  readerPasswordPath,
}:
let
  snapshotRootParent = builtins.dirOf (toString readerSnapshotRoot);
  readerClosure = closureInfo {
    rootPaths = [
      borgbackup
      coreutils
    ];
  };
in
writeShellApplication {
  name = "borg-reader-serve";
  runtimeInputs = [
    bash
    bubblewrap
  ];
  text = ''
    if [ -z "''${SSH_ORIGINAL_COMMAND+x}" ]; then
      echo "borg-reader-serve: missing SSH_ORIGINAL_COMMAND" >&2
      exit 126
    fi

    set -f
    IFS=$' \t\n'

    snapshot_root=${lib.escapeShellArg (toString readerSnapshotRoot)}
    case "$SSH_ORIGINAL_COMMAND" in
      ls*) cwd="$snapshot_root" ;;
      borg*)
        cwd=/tmp
        exec 3< ${lib.escapeShellArg (toString readerPasswordPath)}
        ;;
      *) exit 126 ;;
    esac

    # bubblewrap 0.11 inherits open descriptors and has no --preserve-fds
    # switch.  Keep stdin/stdout/stderr (and the Borg passphrase on fd 3)
    # only; /proc is deliberately not mounted in the reader namespace.
    set +f
    for fd_path in /proc/self/fd/[0-9]*; do
      fd="''${fd_path##*/}"
      case "$fd" in
        0 | 1 | 2 | 3) continue ;;
      esac
      if [ "$fd" -ge 4 ] 2>/dev/null; then
        exec {fd}>&-
      fi
    done
    set -f

    bwrap_args=(
      --unshare-all
      --new-session
      --die-with-parent
      --cap-drop ALL
      --uid 1001
      --gid 1001
      --clearenv
      --dir /nix
      --dir /nix/store
      --dir ${lib.escapeShellArg snapshotRootParent}
      --dev /dev
      --tmpfs /tmp
      --ro-bind "$snapshot_root" "$snapshot_root"
      --chdir "$cwd"
      --setenv HOME /tmp
      --setenv PATH ${coreutils}/bin:${borgbackup}/bin
      --setenv SSH_ORIGINAL_COMMAND "$SSH_ORIGINAL_COMMAND"
    )

    while IFS= read -r store_path; do
      bwrap_args+=(--ro-bind "$store_path" "$store_path")
    done < ${readerClosure}/store-paths

    if [[ "$SSH_ORIGINAL_COMMAND" == borg* ]]; then
      bwrap_args+=(
        --setenv BORG_PASSPHRASE_FD 3
        --setenv BORG_RELOCATED_REPO_ACCESS_IS_OK yes
      )
      if [ -n "''${BORG_REPO+x}" ]; then
        bwrap_args+=(--setenv BORG_REPO "$BORG_REPO")
      fi
    fi

    # shellcheck disable=SC2086
    exec ${bubblewrap}/bin/bwrap "''${bwrap_args[@]}" -- \
      $SSH_ORIGINAL_COMMAND
  '';
}
