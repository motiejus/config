rec {
  uidgid = {
    motiejus = 1000;

    gitea = 995;
    updaterbot-deployer = 501;
    updaterbot-deployee = 502;

    # the underscore differentiates "our" user from the
    # "upstream" user. We need a way to configure the uidgid,
    # so creating users explicitly.
    node_exporter = 503;
  };

  ports = {
    grafana = 3000;
    gitea = 3001;
    soju = 6697;
    matrix-synapse = 8008;
    kodi = 8080;
    prometheus = 9001;
    exporters.node = 9002;
  };

  people_pubkeys = {
    motiejus = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC+qpaaD+FCYPcUU1ONbw/ff5j0xXu5DNvp/4qZH/vOYwG13uDdfI5ISYPs8zNaVcFuEDgNxWorVPwDw4p6+1JwRLlhO4J/5tE1w8Gt6C7y76LRWnp0rCdva5vL3xMozxYIWVOAiN131eyirV2FdOaqTwPy4ouNMmBFbibLQwBna89tbFMG/jwR7Cxt1I6UiYOuCXIocI5YUbXlsXoK9gr5yBRoTjl2OfH2itGYHz9xQCswvatmqrnteubAbkb6IUFYz184rnlVntuZLwzM99ezcG4v8/485gWkotTkOgQIrGNKgOA7UNKpQNbrwdPAMugqfSTo6g8fEvy0Q+6OXdxw5X7en2TJE+BLVaXp4pVMdOAzKF0nnssn64sRhsrUtFIjNGmOWBOR2gGokaJcM6x9R72qxucuG5054pSibs32BkPEg6Qzp+Bh77C3vUmC94YLVg6pazHhLroYSP1xQjfOvXyLxXB1s9rwJcO+s4kqmInft2weyhfaFE0Bjcoc+1/dKuQYfPCPSB//4zvktxTXud80zwWzMy91Q4ucRrHTBz3PrhO8ys74aSGnKOiG3ccD3HbaT0Ff4qmtIwHcAjrnNlINAcH/A2mpi0/2xA7T8WpFnvgtkQbcMF0kEKGnNS5ULZXP/LC8BlLXxwPdqTzvKikkTb661j4PhJhinhVwnQ==";
  };

  hosts = {
    "vno1-oh2.servers.jakst" = rec {
      extraHostNames = ["dl.jakstys.lt" "git.jakstys.lt" "vno1-oh2.jakstys.lt" publicIP jakstIP];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHtYsaht57g2sp6UmLHqsCK+fHjiiZ0rmGceFmFt88pY";
      initrdPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKns3+EIPqKeoB5OIxANIkppb5ICOmkW8X1DOKJPeRWr";
      publicIP = "88.223.107.21";
      jakstIP = "100.89.176.4";
    };
    "vno1-rp3b.servers.jakst" = rec {
      extraHostNames = [jakstIP];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBudUFFEBpUVdr26vLJup8Hk6wj1iDbOPPQnJbv6GUGC";
      jakstIP = "100.89.176.2";
    };
    "hel1-a.servers.jakst" = rec {
      extraHostNames = ["hel1-a.jakstys.lt" "vpn.jakstys.lt" "jakstys.lt" "www.jakstys.lt" publicIP jakstIP];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF6Wd2lKrpP2Gqul10obMo2dc1xKaaLv0I4FAnfIaFKu";
      initrdPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEzt0eaSRTAfM2295x4vACEd5VFqVeYJPV/N9ZUq+voP";
      publicIP = "65.21.7.119";
      jakstIP = "100.89.176.3";
    };
    "fwmine.motiejus.jakst" = {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIPi4N6NhUjAwZNSbi/Eb9zliZtrCzNEHmKb4UGRsJqF";
      jakstIP = "100.89.176.6";
    };
    "mxp10.motiejus.jakst" = {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIy9IR7Jq3hRZ5JgwfmeCgSKFrdgujnZt79uxDPVi3tu";
      jakstIP = "100.89.176.1";
    };
    "zh2769.rsync.net" = {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJtclizeBy1Uo3D86HpgD3LONGVH0CJ0NT+YfZlldAJd";
    };
    "github.com" = {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };
    "git.sr.ht" = {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMZvRd4EtM7R+IHVMWmDkVU3VLQTSwQDSAvW0t2Tkj60";
    };
  };

  tailscale_subnet = {
    cidr = "100.89.176.0/20";
    range = "100.89.176.0-100.89.191.255";
    pattern = "100.89.176.?"; # until we have more hosts
  };

  jakstysLTZone = let
    hel1a = hosts."hel1-a.servers.jakst".publicIP;
    vno1 = hosts."vno1-oh2.servers.jakst".publicIP;
  in ''
    $ORIGIN jakstys.lt.
    $TTL 86400
    @                                SOA   ns1.jakstys.lt. motiejus.jakstys.lt. (2023032100 86400 86400 86400 86400)
    @                                NS    ns1.jakstys.lt.
    @                                NS    ns2.jakstys.lt.
    @                                A     ${vno1}
    www                              A     ${vno1}
    ns1                              A     ${vno1}
    ns2                              A     ${hel1a}
    vpn                 60           A     ${hel1a}
    git                              A     ${vno1}
    auth                             A     ${vno1}
    dl                               A     ${vno1}
    fwmine                           A     ${hel1a}
    hel1-a                           A     ${hel1a}
    vno1                             A     ${vno1}

    @                               MX     10 aspmx.l.google.com.
    @                               MX     20 alt1.aspmx.l.google.com.
    @                               MX     20 alt2.aspmx.l.google.com.
    @                               MX     30 aspmx2.googlemail.com.
    @                               MX     30 aspmx3.googlemail.com.

    grafana                          A     ${hosts."vno1-oh2.servers.jakst".jakstIP}
    _acme-challenge.grafana      CNAME     _acme-endpoint.grafana
    _acme-endpoint.grafana          NS     ns._acme-endpoint.grafana
    ns._acme-endpoint.grafana        A     ${vno1}

    irc                              A     ${hosts."vno1-oh2.servers.jakst".jakstIP}
    _acme-challenge.irc          CNAME     _acme-endpoint.irc
    _acme-endpoint.irc              NS     ns._acme-endpoint.irc
    ns._acme-endpoint.irc            A     ${vno1}
  '';
}
