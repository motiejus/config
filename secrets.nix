let
  motiejus = "age1yubikey1qtwmhf7h7ljs3dyx06wyzme4st6w4calkdpmsxgpxc9t2cldezvasd6n8wg";
  users = [ motiejus ];

  hel1-a = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF6Wd2lKrpP2Gqul10obMo2dc1xKaaLv0I4FAnfIaFKu";
  systems = [ hel1-a ];
in
{
  "secrets/hel1-a/zfs-passphrase.age".publicKeys = [ motiejus hel1-a ];
}
