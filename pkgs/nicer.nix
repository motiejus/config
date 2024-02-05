{
  coreutils,
  writeShellApplication,
}:
writeShellApplication {
  name = "nicer";
  text = ''
    f=$(${coreutils}/bin/mktemp)
    trap '${coreutils}/bin/rm -f "$f"' EXIT
    ${coreutils}/bin/env > "$f"
    systemd-run \
        --user \
        --same-dir \
        --slice nicer \
        --nice=19 \
        --property CPUSchedulingPolicy=idle \
        --property IOSchedulingClass=idle \
        --property IOSchedulingPriority=7 \
        --pty \
        --pipe \
        --wait \
        --collect \
        --quiet \
        --property EnvironmentFile="$f" \
        --service-type=exec \
        -- "$@"
  '';
}
