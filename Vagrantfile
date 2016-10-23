# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.provider "virtualbox" do |vb|
    vb.cpus = 1
    vb.memory = 1024
    vb.name = 'bookstack'
  end
 
  config.vm.define :bookstack do |config|
    config.vm.box = "bento/ubuntu-16.04"
    config.vm.boot_timeout = 1800
    config.ssh.username = 'vagrant'
    config.ssh.password = 'vagrant'
  end
end
