#!/bin/bash

check_os() {
  name=$(cat /etc/os-release | grep ^NAME= | sed 's/"//g')
  clean_name=${name#*=}

  version=$(cat /etc/os-release | grep ^VERSION_ID= | sed 's/"//g')
  clean_version=${version#*=}
  major=${clean_version%.*}
  minor=${clean_version#*.}
  
  if [[ "$clean_name" == "Ubuntu" ]]; then
    operating_system="ubuntu"
  elif [[ "$clean_name" == "Oracle Linux Server" ]]; then
    operating_system="oraclelinux"
  else
    operating_system="undef"
  fi

  echo "K3S install process running on: "
  echo "OS: $operating_system"
  echo "OS Major Release: $major"
  echo "OS Minor Release: $minor"
}

install_oci_cli_ubuntu(){
  # No host NGINX in Option B
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y python3 python3-pip
  pip install oci-cli
}

install_oci_cli_oracle(){
  # No host NGINX in Option B
  if [[ $major -eq 9 ]]; then
    dnf -y install oraclelinux-developer-release-el9
    dnf -y install python39-oci-cli python3-jinja2
  else
    dnf -y install oraclelinux-developer-release-el8
    dnf -y module enable python36:3.6
    dnf -y install python36-oci-cli python3-jinja2
  fi
}

wait_lb() {
while [ true ]
do
  curl --output /dev/null --silent -k https://${k3s_url}:6443
  if [[ "$?" -eq 0 ]]; then
    break
  fi
  sleep 5
  echo "wait for LB"
done
}

check_os

if [[ "$operating_system" == "ubuntu" ]]; then
  # Disable firewall 
  /usr/sbin/netfilter-persistent stop
  /usr/sbin/netfilter-persistent flush

  systemctl stop netfilter-persistent.service
  systemctl disable netfilter-persistent.service

  # END Disable firewall

  apt-get update
  apt-get install -y software-properties-common jq
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

  %{ if ! disable_ingress }
  install_oci_cli_ubuntu
  %{ endif }
  
  # Fix /var/log/journal dir size
  echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
  systemctl restart systemd-journald
fi

if [[ "$operating_system" == "oraclelinux" ]]; then
  # Disable firewall
  systemctl disable --now firewalld
  # END Disable firewall

  # Fix iptables/SELinux bug
  echo '(allow iptables_t cgroup_t (dir (ioctl)))' > /root/local_iptables.cil
  semodule -i /root/local_iptables.cil

  dnf -y update
  dnf -y install jq curl

  %{ if ! disable_ingress }
  install_oci_cli_oracle
  %{ endif }

  setsebool httpd_can_network_connect on -P || true
fi

k3s_install_params=()

%{ if k3s_subnet != "default_route_table" } 
local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')

k3s_install_params+=("--node-ip $local_ip")
k3s_install_params+=("--flannel-iface $flannel_iface")
%{ endif }

if [[ "$operating_system" == "oraclelinux" ]]; then
  k3s_install_params+=("--selinux")
fi

INSTALL_PARAMS="${k3s_install_params[*]}"

%{ if k3s_version == "latest" }
K3S_VERSION=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
%{ else }
K3S_VERSION="${k3s_version}"
%{ endif }

wait_lb

until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_TOKEN=${k3s_token} K3S_URL=https://${k3s_url}:6443 sh -s - $INSTALL_PARAMS); do
  echo 'k3s did not install correctly'
  sleep 2
done

# No host-level NGINX proxying in Option B

%{ if install_longhorn }
if [[ "$operating_system" == "ubuntu" ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y  open-iscsi curl util-linux
fi

systemctl enable --now iscsid.service
%{ endif }
