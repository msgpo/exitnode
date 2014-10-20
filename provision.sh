#!/bin/sh

MESH_IP=10.42.0.99
MESH_MTU=1400
ETH_IF=eth0
PUBLIC_IP="$(ifconfig | grep -A 1 "$ETH_IF" | tail -1 | cut -d ':' -f 2 | cut -d ' ' -f 1)" 

if [ "$#" -le 0 ]
then
  SRC_DIR="/vagrant/"
else
  SRC_DIR="$1"
fi

apt-get update && apt-get install -y --force-yes \
  build-essential \
  ca-certificates \
  curl \
  git \
  libssl-dev \
  libxslt1-dev \
  module-init-tools \
  bridge-utils \
  openssh-server \
  openssl \
  perl \
  dnsmasq \
  squid3 \
  postgresql \
  procps \
  procps \
  python-psycopg2 \
  python-software-properties \
  software-properties-common \
  python \
  python-dev \
  python-pip \
  iproute \
  libnetfilter-conntrack3 \
  libevent-dev \
  ebtables \
  vim \
  tmux \
  linux-headers-amd64

mkdir /root/batman-build
cd /root/batman-build

# batctl wasn't building, so I think for now we can build the version of batman-adv
# that we like and we can use the current debian batctl package. I think it's ok 
# if those two are different - maxb
wget downloads.open-mesh.org/batman/stable/sources/batman-adv/batman-adv-2013.4.0.tar.gz
# wget downloads.open-mesh.org/batman/stable/sources/batctl/batctl-2014.3.0.tar.gz
tar -xvf batman-adv-2013.4.0.tar.gz 
# tar -xvf batctl-2014.3.0.tar.gz
cd batman-adv-2013.4.0
make && make install
# cd ../batctl-2014.3.0
# make && make install
apt-get install -y batctl

REQUIRED_MODULES="nf_conntrack_netlink nf_conntrack nfnetlink l2tp_netlink l2tp_core l2tp_eth batman_adv"

for module in $REQUIRED_MODULES
do
  if grep -q "$module" /etc/modules
  then
    echo "$module already in /etc/modules"
  else
    echo "\n$module" >> /etc/modules
  fi
  modprobe $module
done

# All exitnode file configs
cp -r $SRC_DIR/src/etc/* /etc/
cp -r $SRC_DIR/src/var/* /var/

# Check if bat0 already has configs
if grep -q "bat0" /etc/network/interfaces
then
  echo "bat0 already configured in /etc/network/interfaces"
else
  cat >>/etc/network/interfaces <<EOF

# Batman interface
# (1) Ugly hack to keep bat0 up: add a dummy tap device
# (2) Add iptables rule to masquerade traffic from the mesh
auto bat0
iface bat0 inet static
        pre-up ip tuntap add dev bat-tap mode tap
        pre-up ip link set mtu 1400 dev bat-tap
        pre-up ip link set bat-tap up
        pre-up batctl if add bat-tap
        post-up iptables -t nat -A POSTROUTING -s 10.0.0.0/8 ! -d 10.0.0.0/8 -j MASQUERADE
        post-up iptables -t mangle -A POSTROUTING -s 10.0.0.0/8 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        post-up iptables -t mangle -A POSTROUTING -d 10.0.0.0/8 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        post-up ip link set mtu $MESH_MTU dev bat0
        pre-down iptables -t nat -D POSTROUTING -s 10.0.0.0/8 ! -d 10.0.0.0/8 -j MASQUERADE
        post-up iptables -t mangle -D POSTROUTING -s 10.0.0.0/8 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        post-up iptables -t mangle -D POSTROUTING -d 10.0.0.0/8 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        post-down batctl if del bat-tap
        post-down ip link set bat-tap down
        post-down ip tuntap del dev bat-tap mode tap
        address $MESH_IP
        netmask 255.0.0.0
        mtu $MESH_MTU

# Logical interface to manage adding tunnels to bat0
iface mesh-tunnel inet manual
        up ip link set \$IFACE up
        post-up batctl if add \$IFACE
        post-up ip link set mtu $MESH_MTU dev bat0
        pre-down batctl if del \$IFACE
        down ip link set \$IFACE down
EOF
fi

pip install virtualenv

# rm -rf /opt/tunneldigger # ONLY NECESSARY IF WE WANT TO CLEAN UP LAST TUNNELDIGGER INSTALL
git clone https://github.com/sudomesh/tunneldigger.git /opt/tunneldigger
cd /opt/tunneldigger/broker
virtualenv env_tunneldigger
/opt/tunneldigger/broker/env_tunneldigger/bin/pip install -r requirements.txt

#
# cp /opt/tunneldigger/broker/scripts/tunneldigger-broker.init.d /etc/init.d @@TODO: Understand the difference between the two init scripts!
cp /opt/tunneldigger/broker/scripts/tunneldigger-broker.init.d /etc/init.d/tunneldigger

# Setup public ip in tunneldigger.cfg
# Sorry this is so ugly - I'm not a very good bash programmer - maxb
CFG="/opt/tunneldigger/broker/l2tp_broker.cfg"
sed -i.bak "s/address=[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/address=$PUBLIC_IP/" $CFG
sed -i.bak "s/interface=lo/interface=$ETH_IF/" $CFG 

echo "host captive captive 127.0.0.1/32 md5" >> /etc/postgresql/9.1/main/pg_hba.conf 

cp $SRC_DIR/setupcaptive.sql /home/
cd /home
/etc/init.d/postgresql restart; su postgres -c "ls -la";su postgres -c "pwd"; su postgres -c "psql -f setupcaptive.sql -d postgres"

# @@TODO - Do we need to add these to startup?
# adding init.d scripts to startup
update-rc.d tunneldigger defaults
#update-rc.d gateway defaults

service tunneldigger start

# Squid + redirect stuff for captive portal
# /etc/init.d/squid restart
# /etc/init.d/captive_portal_redirect start

# node stuffs
#cp $SRC_DIR/.profile ~/.profile
# mkdir ~/nvm
# cd ~/nvm
# curl https://raw.githubusercontent.com/creationix/nvm/v0.10.0/install.sh | bash
# source ~/.profile; 
# nvm install 0.10; 
# nvm use 0.10;


# ssh stuffs
# @@TODO: BETTER PASSWORD/Public Key
# echo 'root:sudoer' | chpasswd

# nginx stuffs
echo "deb http://nginx.org/packages/debian/ wheezy nginx" >> /etc/apt/sources.list
echo "deb-src http://nginx.org/packages/debian/ wheezy nginx" >> /etc/apt/sources.list
apt-get update
apt-get install -y --force-yes nginx
cp $SRC_DIR/nginx.conf /etc/nginx/nginx.conf
update-rc.d nginx defaults
service nginx start

# IP Forwarding
sed -i.backup 's/\(.*net.ipv4.ip_forward.*\)/# Enable forwarding for mesh (altered by provisioning script)\nnet.ipv4.ip_forward=1/' /etc/sysctl.conf
echo "1" > /proc/sys/net/ipv4/ip_forward

shutdown -r now
