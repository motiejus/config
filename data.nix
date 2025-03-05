rec {
  uidgid = {
    motiejus = 1000;

    gitea = 20000;
    updaterbot-deployer = 501;
    updaterbot-deployee = 502;

    # the underscore differentiates "our" user from the
    # "upstream" user. We need a way to configure the uidgid,
    # so creating users explicitly.
    node_exporter = 503;

    borgstor = 504;

    jakstpub = 505;

    remote-builder = 508;
  };

  ports = {
    grafana = 3000;
    gitea = 3001;
    immich-server = 3002;
    immich-machine-learning = 3003; # as of writing, hardcoded in the immich module

    frigate = 5000;
    soju = 6697;
    soju-ws = 6698;
    matrix-synapse = 8008;
    ssh8022 = 8022;
    vaultwarden = 8222;
    headscale = 8080;
    hass = 8123;
    prometheus = 9001;
    tailscale = 41641;
    exporters = {

      node = 9002;
      weather = 9011;
      # non-configurable in caddy as of 2023-09-06
      caddy = 2019;
    };
  };

  people_pubkeys = {
    motiejus = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC+qpaaD+FCYPcUU1ONbw/ff5j0xXu5DNvp/4qZH/vOYwG13uDdfI5ISYPs8zNaVcFuEDgNxWorVPwDw4p6+1JwRLlhO4J/5tE1w8Gt6C7y76LRWnp0rCdva5vL3xMozxYIWVOAiN131eyirV2FdOaqTwPy4ouNMmBFbibLQwBna89tbFMG/jwR7Cxt1I6UiYOuCXIocI5YUbXlsXoK9gr5yBRoTjl2OfH2itGYHz9xQCswvatmqrnteubAbkb6IUFYz184rnlVntuZLwzM99ezcG4v8/485gWkotTkOgQIrGNKgOA7UNKpQNbrwdPAMugqfSTo6g8fEvy0Q+6OXdxw5X7en2TJE+BLVaXp4pVMdOAzKF0nnssn64sRhsrUtFIjNGmOWBOR2gGokaJcM6x9R72qxucuG5054pSibs32BkPEg6Qzp+Bh77C3vUmC94YLVg6pazHhLroYSP1xQjfOvXyLxXB1s9rwJcO+s4kqmInft2weyhfaFE0Bjcoc+1/dKuQYfPCPSB//4zvktxTXud80zwWzMy91Q4ucRrHTBz3PrhO8ys74aSGnKOiG3ccD3HbaT0Ff4qmtIwHcAjrnNlINAcH/A2mpi0/2xA7T8WpFnvgtkQbcMF0kEKGnNS5ULZXP/LC8BlLXxwPdqTzvKikkTb661j4PhJhinhVwnQ==";
    motiejus_work = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBRQxp99COE6iLVOrIrpbSAefbdiHoy0luN5VSr4I2SP";
  };

  hosts = {
    "vno4-rutx11.servers.jakst" = rec {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMEehmFvEBVngwxk1nuEWMlE4UU69gC4wxytGX5DAFbh";
      publicIP = "188.69.241.222";
      jakstIP = "100.89.176.10";
      vno4IP = "192.168.188.1";
      extraHostNames = [
        "vno4.jakstys.lt"
        publicIP
        jakstIP
        vno4IP
      ];
    };
    "vno3-nk.servers.jakst" = rec {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBp3QL8p4AbuijEQX/uVHj6nkJ2/8qNSciL+Glydw2yK";
      system = "x86_64-linux";
      jakstIP = "100.89.176.5";
      extraHostNames = [
        jakstIP
      ];
    };
    "fra1-b.servers.jakst" = rec {
      extraHostNames = [
        "fra1-b.jakstys.lt"
        publicIP
        jakstIP
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1tL1FQeKE+28ATuD4USa4oAdPkONfk4uF/McMm+2sy";
      publicIP = "188.245.84.21";
      jakstIP = "100.89.176.18";
      system = "aarch64-linux";
      supportedFeatures = [
        "nixos-test"
        "benchmark"
        "big-parallel"
        "kvm"
        "gccarch-armv8-a"
      ];
    };
    "vno1-gdrx.motiejus.jakst" = rec {
      extraHostNames = [
        vno1IP
        jakstIP
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPW7k8wMOIWKERGiMlz5kX/PXJ/EbzUnJK6jVgPtAbNF";
      vno1IP = "192.168.189.12";
      jakstIP = "100.89.176.21";
    };
    "fwminex.servers.jakst" = rec {
      extraHostNames = [
        "jakstys.lt"
        "git.jakstys.lt"
        "dl.jakstys.lt"
        "irc.jakstys.lt"
        "www.jakstys.lt"
        "vpn.jakstys.lt"
        jakstIP
        vno1IP
        publicIP
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHlWSZ/H6DR5i5aCrlrEQLVF9MXNvls/pjlLPLaav3f+";
      publicIP = "88.223.107.21";
      jakstIP = "100.89.176.6";
      vno1IP = "192.168.189.10";
    };
    "mtworx.motiejus.jakst" = rec {
      extraHostNames = [ jakstIP ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK/2oa3/NDV7GQNAKEQdJ+LZMwK0TUr1wChJMkZM1I3b";
      jakstIP = "100.89.176.3";
    };
    "vno1-vinc.vincentas.jakst" = rec {
      extraHostNames = [ jakstIP ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJIwK7et5NBM+vaffiwpKLSAJwKfwMhCZwl1JyXo79uL";
      jakstIP = "100.89.176.7";
    };
    "mxp1.motiejus.jakst" = {
      jakstIP = "100.89.176.22";
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
      sshPattern = "100.89.176.*"; # until we have more hosts
    };
    motiejus.cidrs =
      let
        mHosts = attrVals [
          "mxp1.motiejus.jakst"
          "vno1-gdrx.motiejus.jakst"
          "mtworx.motiejus.jakst"
          "fwminex.servers.jakst"
        ] hosts;
      in
      builtins.catAttrs "jakstIP" mHosts;

    vno1 = {
      cidr = "192.168.189.0/24";
      sshPattern = "192.168.189.*";
    };
    vno3.cidr = "192.168.100.0/24";
  };

  jakstysLTZone =
    let
      fra1b = hosts."fra1-b.servers.jakst".publicIP;
      vno1 = hosts."fwminex.servers.jakst".publicIP;
      vno4 = hosts."vno4-rutx11.servers.jakst".publicIP;
    in
    ''
      $ORIGIN jakstys.lt.
      $TTL 3600
      @                       86400   SOA     ns1.jakstys.lt. motiejus.jakstys.lt. (2023100800 86400 86400 86400 86400)
      @                       86400    NS     ns1.jakstys.lt.
      @                       86400    NS     ns2.jakstys.lt.
      @                             HTTPS     1 . alpn="h3,h2" ipv4hint="${vno1}"
      @                                A     ${vno1}
      www                              A     ${vno1}
      photos                           A     ${hosts."fwminex.servers.jakst".jakstIP}
      ns1                     86400    A     ${vno1}
      ns2                     86400    A     ${fra1b}
      vpn                              A     ${vno1}
      git                              A     ${vno1}
      git                          HTTPS     1 . alpn="h3,h2" ipv4hint="${vno1}"
      auth                             A     ${vno1}
      dl                               A     ${vno1}
      fra1-b                           A     ${fra1b}
      vno4                             A     ${vno4}
      r1                               A     ${vno1}

      @                               TXT    google-site-verification=sU99fmO8gEJF-0lbOY-IzkovC6MXsP3Gozqrs8BR5OM
      @                               TXT    hosted-email-verify=rvyd6h64
      @                                MX    10 smtp.google.com.
      _submission._tcp                SRV    0 1 587 smtp.gmail.com.
      _imaps._tcp                     SRV    0 1 993 imap.gmail.com.
      _pop3s._tcp                     SRV    0 1 995 pop.gmail.com.
      @                               TXT    "v=spf1 include:_spf.google.com ~all"
      _dmarc                          TXT    "v=DMARC1; p=none;"
      google._domainkey               TXT    "v=DKIM1; k=rsa;" "p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuqOyONnWKk7lgAVB1UcVu/I02gTDjROpQGDNUJHS34faQ9DnM/8uSOaIwCe4oV1GrI8N2ET+f96WPCCs1LzlEA0QwuUoXRLGojjQoXxCntLfMCnRWtehzmZq6Yv8nVva7N0gz/n/LThpPvGfEoKzYjmhjzM5d8y60DGsKxS8r4Lc9TzwtzuYkxKDhcSzVBQQiMvKMi6m6mUsxFya7" "ZTurd5i7iiZXpA3SFBYLAsjhQd6vS7K13vwAZTKjGNijfM40i7KXC5XA5WtojiSY0lZzAMqaHGLDaMUFkWRJJntRheQ+AU9RvOGAufphRAjdQTCMy0BLzC0rilT2JaTGe4MdQIDAQAB"

      grafana                             A     ${hosts."fwminex.servers.jakst".jakstIP}
      _acme-challenge.grafana         CNAME     _acme-endpoint.grafana
      _acme-endpoint.grafana             NS     ns._acme-endpoint.grafana
      ns._acme-endpoint.grafana           A     ${vno1}

      hass                                A     ${hosts."fwminex.servers.jakst".jakstIP}
      _acme-challenge.hass            CNAME     _acme-endpoint.hass
      _acme-endpoint.hass                NS     ns._acme-endpoint.hass
      ns._acme-endpoint.hass              A     ${vno1}

      irc                                 A     ${hosts."fwminex.servers.jakst".jakstIP}
      _acme-challenge.irc             CNAME     _acme-endpoint.irc
      _acme-endpoint.irc                 NS     ns._acme-endpoint.irc
      ns._acme-endpoint.irc               A     ${vno1}

      hass                                A     ${hosts."fwminex.servers.jakst".jakstIP}
      _acme-challenge.hass            CNAME     _acme-endpoint.hass
      _acme-endpoint.hass                NS     ns._acme-endpoint.hass
      ns._acme-endpoint.hass              A     ${vno1}

      bitwarden                       HTTPS     1 . alpn="h3,h2" ipv4hint="${
        hosts."fwminex.servers.jakst".jakstIP
      }"
      bitwarden                           A     ${hosts."fwminex.servers.jakst".jakstIP}
      _acme-challenge.bitwarden       CNAME     _acme-endpoint.bitwarden
      _acme-endpoint.bitwarden           NS     ns._acme-endpoint.bitwarden
      ns._acme-endpoint.bitwarden         A     ${vno1}

      hdd                                 A     ${hosts."vno3-nk.servers.jakst".jakstIP}
      _acme-challenge.hdd             CNAME     _acme-endpoint.hdd
      _acme-endpoint.hdd                 NS     ns._acme-endpoint.hdd
      ns._acme-endpoint.hdd               A     ${vno1}

      _acme-challenge.r1              CNAME     _acme-endpoint.r1
      _acme-endpoint.r1                  NS     ns._acme-endpoint.r1
      ns._acme-endpoint.r1                A     ${vno1}
    '';
}
