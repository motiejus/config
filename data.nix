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

    borgstor = 504;

    jakstpub = 505;

    certget = 506;
  };

  ports = {
    grafana = 3000;
    gitea = 3001;

    # not necessary from vaultwarden 1.29.0
    vaultwarden_ws = 3012;

    soju = 6697;
    matrix-synapse = 8008;
    vaultwarden = 8222;
    kodi = 8080;
    hass = 8123;
    prometheus = 9001;
    tailscale = 41641;
    exporters.node = 9002;

    # non-configurable in caddy as of 2023-09-06
    exporters.caddy = 2019;
  };

  people_pubkeys = {
    motiejus_work = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBttrJeH3Emu2PL/SJ5ccZxHdDsgV65FFED6/jZC8C/f";
    motiejus = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC+qpaaD+FCYPcUU1ONbw/ff5j0xXu5DNvp/4qZH/vOYwG13uDdfI5ISYPs8zNaVcFuEDgNxWorVPwDw4p6+1JwRLlhO4J/5tE1w8Gt6C7y76LRWnp0rCdva5vL3xMozxYIWVOAiN131eyirV2FdOaqTwPy4ouNMmBFbibLQwBna89tbFMG/jwR7Cxt1I6UiYOuCXIocI5YUbXlsXoK9gr5yBRoTjl2OfH2itGYHz9xQCswvatmqrnteubAbkb6IUFYz184rnlVntuZLwzM99ezcG4v8/485gWkotTkOgQIrGNKgOA7UNKpQNbrwdPAMugqfSTo6g8fEvy0Q+6OXdxw5X7en2TJE+BLVaXp4pVMdOAzKF0nnssn64sRhsrUtFIjNGmOWBOR2gGokaJcM6x9R72qxucuG5054pSibs32BkPEg6Qzp+Bh77C3vUmC94YLVg6pazHhLroYSP1xQjfOvXyLxXB1s9rwJcO+s4kqmInft2weyhfaFE0Bjcoc+1/dKuQYfPCPSB//4zvktxTXud80zwWzMy91Q4ucRrHTBz3PrhO8ys74aSGnKOiG3ccD3HbaT0Ff4qmtIwHcAjrnNlINAcH/A2mpi0/2xA7T8WpFnvgtkQbcMF0kEKGnNS5ULZXP/LC8BlLXxwPdqTzvKikkTb661j4PhJhinhVwnQ==";
  };

  hosts = {
    "vno1-oh2.servers.jakst" = rec {
      extraHostNames = [
        "dl.jakstys.lt"
        "git.jakstys.lt"
        "irc.jakstys.lt"
        "vno1-oh2.jakstys.lt"
        "jakstys.lt"
        "www.jakstys.lt"
        "vpn.jakstys.lt"
        publicIP
        jakstIP
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHtYsaht57g2sp6UmLHqsCK+fHjiiZ0rmGceFmFt88pY";
      initrdPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKns3+EIPqKeoB5OIxANIkppb5ICOmkW8X1DOKJPeRWr";
      publicIP = "88.223.107.21";
      jakstIP = "100.89.176.4";
    };
    "vno3-rp3b.servers.jakst" = rec {
      extraHostNames = [jakstIP];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBudUFFEBpUVdr26vLJup8Hk6wj1iDbOPPQnJbv6GUGC";
      jakstIP = "100.89.176.2";
    };
    "fra1-a.servers.jakst" = rec {
      extraHostNames = ["fra1-a.jakstys.lt" publicIP jakstIP];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFj9Ktw9SZQlHe/Pl5MI7PRUcCyTgZgZ0SsvWUmO0wBM";
      initrdPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGtYwVhfmdHRK8YcaRQ3JGSIOK55lEMNSPh33Z0iI+pO";
      publicIP = "168.119.184.134";
      jakstIP = "100.89.176.5";
    };
    "mtwork.motiejus.jakst" = rec {
      extraHostNames = [jakstIP];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHlWSZ/H6DR5i5aCrlrEQLVF9MXNvls/pjlLPLaav3f+";
      jakstIP = "100.89.176.11";
    };
    "fwminex.motiejus.jakst" = rec {
      extraHostNames = [jakstIP vno1IP];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHlWSZ/H6DR5i5aCrlrEQLVF9MXNvls/pjlLPLaav3f+";
      jakstIP = "100.89.176.6";
      vno1IP = "192.168.189.10";
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

  # copied from nixpkgs/lib/attrsets.nix
  attrVals = nameList: set: map (x: set.${x}) nameList;

  subnets = {
    tailscale = {
      cidr = "100.89.176.0/20";
      range = "100.89.176.0-100.89.191.255";
      sshPattern = "100.89.176.?"; # until we have more hosts
    };
    motiejus.cidrs = let
      mHosts =
        attrVals [
          "mxp10.motiejus.jakst"
          "mtwork.motiejus.jakst"
          "fwminex.motiejus.jakst"
        ]
        hosts;
    in
      builtins.catAttrs "jakstIP" mHosts;

    vno1 = {
      cidr = "192.168.189.0/24";
      sshPattern = "192.168.189.?";
    };
    vno3.cidr = "192.168.100.0/24";
  };

  betaJakstysLTZone = let
    vno1 = hosts."vno1-oh2.servers.jakst".publicIP;
  in ''
    $ORIGIN beta.jakstys.lt.
    $TTL 86400
    @                           SOA     ns1.jakstys.lt. motiejus.jakstys.lt. (2023121600 86400 86400 86400 86400)
    @                            NS     ns1.jakstys.lt.
    @                            NS     ns2.jakstys.lt.
    @                             A     ${vno1}
    @                           TXT     hosted-email-verify=czwt2yjp
    @                           TXT     "v=spf1 include:spf.migadu.com -all"
    _dmarc                      TXT     "v=DMARC1; p=quarantine;"
    @                            MX     10 aspmx1.migadu.com.
    @                            MX     20 aspmx2.migadu.com.
    *                            MX     10 aspmx1.migadu.com.
    *                            MX     20 aspmx2.migadu.com.
    key1._domainkey           CNAME     key1.beta.jakstys.lt._domainkey.migadu.com.
    key2._domainkey           CNAME     key2.beta.jakstys.lt._domainkey.migadu.com.
    key3._domainkey           CNAME     key3.beta.jakstys.lt._domainkey.migadu.com.
    autoconfig                CNAME     autoconfig.migadu.com.
    _autodiscover._tcp          SRV     0 1 443 autodiscover.migadu.com.
    _submissions._tcp           SRV     0 1 465 smtp.migadu.com.
    _imaps._tcp                 SRV     0 1 993 imap.migadu.com.
    _pop3s._tcp                 SRV     0 1 995 imap.migadu.com.
  '';

  jakstysLTZone = let
    fra1a = hosts."fra1-a.servers.jakst".publicIP;
    vno1 = hosts."vno1-oh2.servers.jakst".publicIP;
  in ''
    $ORIGIN jakstys.lt.
    $TTL 86400
    @                              SOA     ns1.jakstys.lt. motiejus.jakstys.lt. (2023100800 86400 86400 86400 86400)
    @                               NS     ns1.jakstys.lt.
    @                               NS     ns2.jakstys.lt.
    beta                            NS     ns1.jakstys.lt.
    beta                            NS     ns2.jakstys.lt.
    @                          600   A     ${vno1}
    www                        600   A     ${vno1}
    ns1                              A     ${vno1}
    ns2                              A     ${fra1a}
    vpn                        600   A     ${vno1}
    git                        600   A     ${vno1}
    auth                             A     ${vno1}
    dl                               A     ${vno1}
    fra1-a                           A     ${fra1a}
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

    hass                             A     ${hosts."vno1-oh2.servers.jakst".jakstIP}
    _acme-challenge.hass         CNAME     _acme-endpoint.hass
    _acme-endpoint.hass             NS     ns._acme-endpoint.hass
    ns._acme-endpoint.hass           A     ${vno1}

    bitwarden                        A     ${hosts."vno1-oh2.servers.jakst".jakstIP}
    _acme-challenge.bitwarden    CNAME     _acme-endpoint.bitwarden
    _acme-endpoint.bitwarden        NS     ns._acme-endpoint.bitwarden
    ns._acme-endpoint.bitwarden      A     ${vno1}

    hdd                              A     ${hosts."vno3-rp3b.servers.jakst".jakstIP}
    _acme-challenge.hdd          CNAME     _acme-endpoint.hdd
    _acme-endpoint.hdd              NS     ns._acme-endpoint.hdd
    ns._acme-endpoint.hdd            A     ${vno1}
  '';
}
