let
  motiejus_yk1 = "age1yubikey1qtwmhf7h7ljs3dyx06wyzme4st6w4calkdpmsxgpxc9t2cldezvasd6n8wg";
  motiejus_yk2 = "age1yubikey1qgyvs2ul0enzqf4sscq96zyxk73jnj4lknpemak2hp39lejdwc0s5uzzhpc";
  motiejus_bk1 = "age1kyehn8yr9tfu3w0z4d9p9qrj0tjjh92ljxmz2nyr6xnm7y8kpv5spwwc9n";
  motiejus = [motiejus_yk1 motiejus_yk2 motiejus_bk1];

  hel1-a = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF6Wd2lKrpP2Gqul10obMo2dc1xKaaLv0I4FAnfIaFKu";
  vno1-oh2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHtYsaht57g2sp6UmLHqsCK+fHjiiZ0rmGceFmFt88pY";
  systems = [hel1-a vno1-oh2];
in {
  "secrets/hel1-a/borgbackup/password.age".publicKeys = [hel1-a] ++ motiejus;
  "secrets/hel1-a/postfix/sasl_passwd.age".publicKeys = [hel1-a] ++ motiejus;
  "secrets/hel1-a/turn/static_auth_secret.age".publicKeys = [hel1-a] ++ motiejus;
  "secrets/hel1-a/synapse/jakstys_lt_signing_key.age".publicKeys = [hel1-a] ++ motiejus;
  "secrets/hel1-a/synapse/registration_shared_secret.age".publicKeys = [hel1-a] ++ motiejus;
  "secrets/hel1-a/synapse/macaroon_secret_key.age".publicKeys = [hel1-a] ++ motiejus;

  "secrets/motiejus_passwd_hash.age".publicKeys = [hel1-a vno1-oh2] ++ motiejus;
  "secrets/root_passwd_hash.age".publicKeys = [hel1-a vno1-oh2] ++ motiejus;
}
