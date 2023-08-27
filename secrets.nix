let
  motiejus_yk1 = "age1yubikey1qtwmhf7h7ljs3dyx06wyzme4st6w4calkdpmsxgpxc9t2cldezvasd6n8wg";
  motiejus_yk2 = "age1yubikey1qgyvs2ul0enzqf4sscq96zyxk73jnj4lknpemak2hp39lejdwc0s5uzzhpc";
  motiejus_bk1 = "age1kyehn8yr9tfu3w0z4d9p9qrj0tjjh92ljxmz2nyr6xnm7y8kpv5spwwc9n";
  motiejus = [motiejus_yk1 motiejus_yk2 motiejus_bk1];

  fra1-a = (import ./data.nix).hosts."fra1-a.servers.jakst".publicKey;
  vno1-oh2 = (import ./data.nix).hosts."vno1-oh2.servers.jakst".publicKey;
  vno1-rp3b = (import ./data.nix).hosts."vno1-rp3b.servers.jakst".publicKey;
  systems = [fra1-a vno1-oh2 vno1-rp3b];

  mk = auth: keyNames:
    builtins.listToAttrs (
      map (keyName: {
        name = keyName;
        value = {publicKeys = auth;};
      })
      keyNames
    );
in
  {}
  // mk ([vno1-oh2] ++ motiejus) [
    "secrets/fra1-a/zfs-passphrase.age"
    "secrets/vno1-oh2/borgbackup/password.age"
    "secrets/grafana.jakstys.lt/oidc.age"
    "secrets/letsencrypt/account.key.age"
    "secrets/headscale/oidc_client_secret2.age"

    "secrets/synapse/jakstys_lt_signing_key.age"
    "secrets/synapse/registration_shared_secret.age"
    "secrets/synapse/macaroon_secret_key.age"
  ]
  # TODO make sure secrets don't repeat here.
  // mk ([fra1-a] ++ motiejus) [
    "secrets/vno1-oh2/zfs-passphrase.age"
  ]
  // mk (systems ++ motiejus) [
    "secrets/motiejus_passwd_hash.age"
    "secrets/root_passwd_hash.age"
    "secrets/postfix_sasl_passwd.age"
  ]
