let
  motiejus = builtins.attrValues {
    yk1 = "age1yubikey1qtwmhf7h7ljs3dyx06wyzme4st6w4calkdpmsxgpxc9t2cldezvasd6n8wg";
    yk2 = "age1yubikey1qgyvs2ul0enzqf4sscq96zyxk73jnj4lknpemak2hp39lejdwc0s5uzzhpc";
    bk1 = "age1kyehn8yr9tfu3w0z4d9p9qrj0tjjh92ljxmz2nyr6xnm7y8kpv5spwwc9n";
    bk2 = "age14f39j0wx84n93lgqn6d9gcd3yhuwak6qwrxy8v83ydn7266uafts09ecva";
  };

  fwminex = (import ./data.nix).hosts."fwminex.servers.jakst".publicKey;
  mtworx = (import ./data.nix).hosts."mtworx.motiejus.jakst".publicKey;
  fra1-b = (import ./data.nix).hosts."fra1-b.servers.jakst".publicKey;
  vno1-gdrx = (import ./data.nix).hosts."vno1-gdrx.motiejus.jakst".publicKey;
  systems = [
    fra1-b
    vno1-gdrx
    fwminex
    mtworx
  ];

  mk =
    auth: keyNames:
    builtins.listToAttrs (
      map (keyName: {
        name = keyName;
        value = {
          publicKeys = auth;
        };
      }) keyNames
    );
in
{ }
// mk ([ mtworx ] ++ motiejus) [
  "secrets/motiejus_work_passwd_hash.age"
  "secrets/root_work_passwd_hash.age"

  "secrets/mtworx/syncthing/key.pem.age"
  "secrets/mtworx/syncthing/cert.pem.age"
  "secrets/mtworx/kolide-launcher.age"
]
// mk ([ vno1-gdrx ] ++ motiejus) [
  "secrets/vno1-gdrx/syncthing/key.pem.age"
  "secrets/vno1-gdrx/syncthing/cert.pem.age"
]
// mk ([ fwminex ] ++ motiejus) [
  "secrets/motiejus_server_passwd_hash.age"
  "secrets/root_server_passwd_hash.age"

  "secrets/headscale/oidc_client_secret2.age"
  "secrets/grafana.jakstys.lt/oidc.age"
  "secrets/vaultwarden/secrets.env.age"
  "secrets/letsencrypt/account.key.age"

  "secrets/synapse/jakstys_lt_signing_key.age"
  "secrets/synapse/registration_shared_secret.age"
  "secrets/synapse/macaroon_secret_key.age"

  "secrets/fwminex/syncthing/key.pem.age"
  "secrets/fwminex/syncthing/cert.pem.age"
]
// mk (
  [
    fwminex
    vno1-gdrx
  ]
  ++ motiejus
) [ "secrets/fwminex/borgbackup-password.age" ]
// mk (systems ++ motiejus) [
  "secrets/motiejus_passwd_hash.age"
  "secrets/root_passwd_hash.age"
  "secrets/postfix_sasl_passwd.age"
  "secrets/ssh8022.age"
]
