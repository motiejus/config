Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/bionic64"

  config.vm.provision 'shell', inline: <<-SHELL
    apt-get update
    apt-get install --no-install-recommends -y vim propellor
  SHELL
end
