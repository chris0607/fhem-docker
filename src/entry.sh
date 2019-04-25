#!/bin/bash
#
#	Credits for the initial process handling to Joscha Middendorf:
#    https://raw.githubusercontent.com/JoschaMiddendorf/fhem-docker/master/StartAndInitialize.sh

export FHEM_DIR="/opt/fhem"
export SLEEPINTERVAL=0.5
export TIMEOUT="${TIMEOUT:-10}"
export RESTART="${RESTART:-1}"
export TELNETPORT="${TELNETPORT:-7072}"
export CONFIGTYPE="${CONFIGTYPE:-"fhem.cfg"}"
export DNS=$( cat /etc/resolv.conf | grep -m1 nameserver | cut -d " " -f 2 )
export DOCKER_GW="${DOCKER_GW:-$(ip -4 route list match 0/0 | cut -d' ' -f3)}"
export DOCKER_HOST="${DOCKER_HOST:-${DOCKER_GW}}"
export FHEM_UID="${FHEM_UID:-6061}"
export FHEM_GID="${FHEM_GID:-6061}"
export FHEM_CLEANINSTALL=1

export BLUETOOTH_GID="${BLUETOOTH_GID:-6001}"
export GPIO_GID="${GPIO_GID:-6002}"
export I2C_GID="${I2C_GID:-6003}"

export APT_PKGS="${APT_PKGS:-}"
export CPAN_PKGS="${CPAN_PKGS:-}"
export PIP_PKGS="${PIP_PKGS:-}"
export NPM_PKGS="${NPM_PKGS:-}"

[ ! -f /image_info.EMPTY ] && touch /image_info.EMPTY

# Collect info about container
ip link add dummy0 type dummy >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
  echo 1 > /docker.privileged
  ip link delete dummy0 >/dev/null
  export DOCKER_PRIVILEGED=1
else
  echo 0 > /docker.privileged
  export DOCKER_PRIVILEGED=0
fi
ip -4 addr show docker0 >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
  echo 1 > /docker.hostnetwork
  export DOCKER_HOSTNETWORK=1
  unset DOCKER_HOST
  unset DOCKER_GW
else
  echo 0 > /docker.hostnetwork
  export DOCKER_HOSTNETWORK=0
fi
cat /proc/self/cgroup | grep "memory:" | cut -d "/" -f 3 > /docker.container.id
captest --text | grep -P "^Effective:" | cut -d " " -f 2- | sed "s/, /\n/g" | sort | sed ':a;N;$!ba;s/\n/,/g' > /docker.container.cap.e
captest --text | grep -P "^Permitted:" | cut -d " " -f 2- | sed "s/, /\n/g" | sort | sed ':a;N;$!ba;s/\n/,/g' > /docker.container.cap.p
captest --text | grep -P "^Inheritable:" | cut -d " " -f 2- | sed "s/, /\n/g" | sort | sed ':a;N;$!ba;s/\n/,/g' > /docker.container.cap.i

# This is a brand new container
if [ -d "/fhem" ]; then
  echo "Preparing initial start:"
  i=1

  [ -s "${FHEM_DIR}/fhem.pl" ] && FHEM_CLEANINSTALL=0

  if [ -s /pre-init.sh ]; then
    echo "$i. Running pre-init script"
    chmod 755 /pre-init.sh
    /pre-init.sh
    (( i++ ))
  fi

  if [ "${APT_PKGS}" != '' ]; then
    echo "$i. Adding custom APT packages to container ..."
    DEBIAN_FRONTEND=noninteractive apt-get update >>/pkgs.apt 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ${APT_PKGS} \
    >>/pkgs.apt 2>&1
    (( i++ ))
  fi

  if [ "${CPAN_PKGS}" != '' ]; then
    if [ ! -e /usr/bin/cpanm ] && [ ! -e /usr/local/bin/cpanm ]; then
      echo "$i. Installing cpanminus ..."
      DEBIAN_FRONTEND=noninteractive apt-get update >>/pkgs.apt 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        cpanminus \
      >>/pkgs.apt 2>&1
      (( i++ ))
    fi

    echo "$i. Adding custom Perl modules to container ..."
    cpanm \
      ${CPAN_PKGS} \
    >>/pkgs.cpan 2>&1
    (( i++ ))
  fi

  if [ "${PIP_PKGS}" != '' ]; then
    if [ ! -e /usr/bin/pip3 ]; then
      echo "$i. Installing pip3 ..."
      DEBIAN_FRONTEND=noninteractive apt-get update >>/pkgs.pip 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
      >>/pkgs.pip 2>&1
      (( i++ ))
    fi

    echo "$i. Adding custom Python modules to container ..."
    pip3 install \
      ${PIP_PKGS} \
    >>/pkgs.pip 2>&1
    (( i++ ))
  fi

  if [ "${NPM_PKGS}" != '' ]; then
    if [ ! -e /usr/bin/npm ]; then
      MTYPE=$(uname -m)
      if [ "${MTYPE}" = 'arm32v5' ]; then
        echo "ERROR: Missing Node.js for ${MTYPE} platform cannot be installed automatically"
        exit 1
      fi

      echo "$i. Adding APT sources for Node.js ..."
      if [ "${MTYPE}" = "i386" ]; then
        curl -fsSL https://deb.nodesource.com/setup_8.x | bash - >>/pkgs.npm 2>&1
      else
        curl -fsSL https://deb.nodesource.com/setup_10.x | bash - >>/pkgs.npm 2>&1
      fi
      (( i++ ))

      echo "$i. Installing Node.js ..."
      DEBIAN_FRONTEND=noninteractive apt-get update >>/pkgs.npm 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        nodejs \
      >>/pkgs.npm 2>&1
      (( i++ ))
    fi

    echo "$i. Adding custom Node.js packages to container ..."
    npm install -g --unsafe-perm --production \
      ${NPM_PKGS} \
    >>/pkgs.npm 2>&1
    (( i++ ))
  fi

  if [ "${FHEM_CLEANINSTALL}" = '1' ]; then
    echo "$i. Installing FHEM to ${FHEM_DIR}"
    shopt -s dotglob nullglob 2>&1>/dev/null
    mv -f /fhem/* ${FHEM_DIR}/ 2>&1>/dev/null
    cd ${FHEM_DIR} 2>&1>/dev/null
    mv ./controls_fhem.txt ./FHEM/ 2>&1>/dev/null
    perl ./contrib/commandref_modular.pl 2>&1>/dev/null
    cp -f ./fhem.cfg ./fhem.cfg.default
    (( i++ ))

    echo "$i. Patching fhem.cfg default configuration"
    [ -z "$(cat ${FHEM_DIR}/fhem.cfg | grep -P '^attr global dnsServer')" ] && echo "attr global dnsServer ${DNS}" >> ${FHEM_DIR}/fhem.cfg
    [ -z "$(cat ${FHEM_DIR}/fhem.cfg | grep -P '^attr global commandref')" ] && echo "attr global commandref modular" >> ${FHEM_DIR}/fhem.cfg
    [ -z "$(cat ${FHEM_DIR}/fhem.cfg | grep -P '^attr global mseclog')" ] && echo "attr global mseclog 1" >> ${FHEM_DIR}/fhem.cfg
    (( i++ ))

    echo "$i. Adding pre-defined devices to fhem.cfg"

    echo "define DockerImageInfo DockerImageInfo" >> ${FHEM_DIR}/fhem.cfg
    echo "attr DockerImageInfo alias Docker Image Info" >> ${FHEM_DIR}/fhem.cfg
    echo "attr DockerImageInfo devStateIcon ok:security@green Initialized:system_fhem_reboot@orange .*:message_attention@red" >> ${FHEM_DIR}/fhem.cfg
    echo "attr DockerImageInfo group System" >> ${FHEM_DIR}/fhem.cfg
    echo "attr DockerImageInfo icon docker" >> ${FHEM_DIR}/fhem.cfg
    echo "attr DockerImageInfo room System" >> ${FHEM_DIR}/fhem.cfg
    echo "define fhemServerApt AptToDate localhost" >> ${FHEM_DIR}/fhem.cfg
    echo "attr fhemServerApt alias System Update Status" >> ${FHEM_DIR}/fhem.cfg
    echo "attr fhemServerApt devStateIcon system.updates.available:security@red system.is.up.to.date:security@green:repoSync .*in.progress:system_fhem_reboot@orange errors:message_attention@red" >> ${FHEM_DIR}/fhem.cfg
    echo "attr fhemServerApt group Update" >> ${FHEM_DIR}/fhem.cfg
    echo "attr fhemServerApt icon debian" >> ${FHEM_DIR}/fhem.cfg
    echo "attr fhemServerApt room System" >> ${FHEM_DIR}/fhem.cfg

    if [ -e /usr/bin/npm ]; then
      echo "define fhemServerNpm npmjs localhost" >> ${FHEM_DIR}/fhem.cfg
      echo "attr fhemServerNpm alias Node.js Package Update Status" >> ${FHEM_DIR}/fhem.cfg
      echo "attr fhemServerNpm devStateIcon npm.updates.available:security@red:outdated npm.is.up.to.date:security@green:outdated .*npm.outdated.*in.progress:system_fhem_reboot@orange .*in.progress:system_fhem_update@orange warning.*:message_attention@orange error.*:message_attention@red" >> ${FHEM_DIR}/fhem.cfg
      echo "attr fhemServerNpm group Update" >> ${FHEM_DIR}/fhem.cfg
      echo "attr fhemServerNpm icon npm-old" >> ${FHEM_DIR}/fhem.cfg
      echo "attr fhemServerNpm room System" >> ${FHEM_DIR}/fhem.cfg
    fi

    if [ -e /usr/bin/cpanm ] || [ -e /usr/local/bin/cpanm ]; then
      echo "define fhemInstaller Installer" >> ${FHEM_DIR}/fhem.cfg
      echo "attr fhemInstaller alias FHEM Installer Status" >> ${FHEM_DIR}/fhem.cfg
      echo "attr fhemInstaller devStateIcon .*updates.available:security@red:outdated up.to.date:security@green:outdated .*outdated.*in.progress:system_fhem_reboot@orange .*in.progress:system_fhem_update@orange warning.*:message_attention@orange error.*:message_attention@red" >> ${FHEM_DIR}/fhem.cfg
      echo "attr fhemInstaller group Update" >> ${FHEM_DIR}/fhem.cfg
      echo "attr fhemInstaller icon system_fhem" >> ${FHEM_DIR}/fhem.cfg
      echo "attr fhemInstaller room System" >> ${FHEM_DIR}/fhem.cfg
    fi

    cd - 2>&1>/dev/null
  else
    echo "$i. Updating existing FHEM installation in ${FHEM_DIR}"
    cp -f ${FHEM_DIR}/fhem.cfg ${FHEM_DIR}/fhem.cfg.bak
    cp -f /fhem/FHEM/99_DockerImageInfo.pm ${FHEM_DIR}/FHEM/
  fi
  (( i++ ))

  rm -rf /fhem/

  if [ -s /post-init.sh ]; then
    echo "$i. Running post-init script"
    chmod 755 /post-init.sh
    /post-init.sh
    (( i++ ))
  fi

  echo -e '\n\n'

elif [ ! -s "${FHEM_DIR}/fhem.pl" ]; then
  echo "- ERROR: Unable to find FHEM installation in ${FHEM_DIR}/fhem.pl"
  exit 1
fi

# determine global logfile
if [ -z "${LOGFILE}" ]; then
  if [ "${CONFIGTYPE}" == "configDB" ]; then
    export LOGFILE="${FHEM_DIR}/./log/fhem-%Y-%m.log"
  else
    GLOGFILE=$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P '^attr global logfile' | cut -d ' ' -f 4)
    export LOGFILE="${FHEM_DIR}/${GLOGFILE:-./log/fhem-%Y-%m.log}"
  fi
else
  export LOGFILE="${FHEM_DIR}/${LOGFILE}"
fi

# determine PID file
if [ -z "${PIDFILE}" ]; then
  if [ "${CONFIGTYPE}" == "configDB" ]; then
    export PIDFILE="${FHEM_DIR}/./log/fhem.pid"
  else
    GPIDFILE=$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P '^attr global pidfilename' | cut -d ' ' -f 4)
    export PIDFILE="${FHEM_DIR}/${GPIDFILE:-./log/fhem.pid}"
  fi
else
  export PIDFILE="${FHEM_DIR}/${PIDFILE}"
fi

# creating user environment
echo "Preparing user environment ..."
i=1
[ ! -s /etc/passwd.orig ] && cp -f /etc/passwd /etc/passwd.orig
[ ! -s /etc/shadow.orig ] && cp -f /etc/shadow /etc/shadow.orig
[ ! -s /etc/group.orig ] && cp -f /etc/group /etc/group.orig
cp -f /etc/passwd.orig /etc/passwd
cp -f /etc/shadow.orig /etc/shadow
cp -f /etc/group.orig /etc/group
echo "$i. Creating group 'fhem' with GID ${FHEM_GID} ..."
groupadd --force --gid ${FHEM_GID} --non-unique fhem 2>&1>/dev/null
(( i++ ))
echo "$i. Enforcing GID for group 'bluetooth' to ${BLUETOOTH_GID} ..."
sed -i "s/^bluetooth\:.*/bluetooth\:x\:${BLUETOOTH_GID}/" /etc/group
(( i++ ))
echo "$i. Creating user 'fhem' with UID ${FHEM_UID} ..."
useradd --home ${FHEM_DIR} --shell /bin/bash --uid ${FHEM_UID} --no-create-home --no-user-group --non-unique fhem 2>&1>/dev/null
usermod --append --gid ${FHEM_GID} --groups ${FHEM_GID} fhem 2>&1>/dev/null
adduser --quiet fhem audio 2>&1>/dev/null
adduser --quiet fhem bluetooth 2>&1>/dev/null
adduser --quiet fhem dialout 2>&1>/dev/null
adduser --quiet fhem mail 2>&1>/dev/null
adduser --quiet fhem tty 2>&1>/dev/null
adduser --quiet fhem video 2>&1>/dev/null
(( i++ ))
echo "$i. Enforcing user and group ownership for ${FHEM_DIR} to fhem:fhem ..."
chown --recursive --quiet --no-dereference ${FHEM_UID}:${FHEM_GID} ${FHEM_DIR}/ 2>&1>/dev/null
(( i++ ))
echo "$i. Correcting group ownership for /dev/tty* ..."
#find /dev/ -name "tty*" -exec chown --recursive --quiet --no-dereference .tty {} \;
find /dev/ -name "ttyS*" -exec chown --recursive --quiet --no-dereference .dialout {} \;
find /dev/ -name "ttyACM*" -exec chown --recursive --quiet --no-dereference .dialout {} \;
find /dev/ -name "ttyUSB*" -exec chown --recursive --quiet --no-dereference .dialout {} \;
#find /dev/ -name "tty*" -exec chmod --recursive --quiet g+w {} \;
find /dev/ -name "ttyS*" -exec chmod --recursive --quiet g+rw {} \;
find /dev/ -name "ttyACM*" -exec chmod --recursive --quiet g+rw {} \;
find /dev/ -name "ttyUSB*" -exec chmod --recursive --quiet g+rw {} \;
(( i++ ))
echo "$i. Correcting group ownership for /dev/serial/* ..."
find /dev/serial/by-id/ -exec chown --recursive --quiet --no-dereference .dialout {} \;
find /dev/serial/by-id/ -exec chmod --recursive --quiet g+rw {} \;
(( i++ ))
if [[ "$(find /dev/ -name "gpio*")" -ne "" || -d /sys/devices/virtual/gpio || -d /sys/devices/platform/gpio-sunxi/gpio || /sys/class/gpio ]]; then
  echo "$i. Found GPIO: Correcting group permissions in /dev and /sys to 'gpio' with GID ${GPIO_GID} ..."
  if [ -n "$(grep ^gpio: /etc/group)" ]; then
    sed -i "s/^gpio\:.*/gpio\:x\:${GPIO_GID}/" /etc/group
  else
    groupadd --force --gid ${GPIO_GID} --non-unique gpio 2>&1>/dev/null
  fi
  adduser --quiet fhem gpio 2>&1>/dev/null
  find /dev/ -name "gpio*" -exec chown --recursive --quiet --no-dereference .gpio {} \;
  find /dev/ -name "gpio*" -exec chmod --recursive --quiet g+rw {} \;
  [ -d /sys/devices/virtual/gpio ] && chown --recursive --quiet --no-dereference .gpio /sys/devices/virtual/gpio/* 2>&1>/dev/null && chmod --recursive --quiet g+w /sys/devices/virtual/gpio/*
  [ -d /sys/devices/platform/gpio-sunxi/gpio ] && chown --recursive --quiet --no-dereference .gpio /sys/devices/platform/gpio-sunxi/gpio/* 2>&1>/dev/null && chmod --recursive --quiet g+w /sys/devices/platform/gpio-sunxi/gpio/*
  [ -d /sys/class/gpio ] && chown --recursive --quiet --no-dereference .gpio /sys/class/gpio/* 2>&1>/dev/null && chmod --recursive --quiet g+w /sys/class/gpio/*
  (( i++ ))
fi
if [ -n "$(grep ^i2c: /etc/group)" ]; then
  echo "$i. Found I2C: Correcting group permissions in /dev to 'i2c' with GID ${I2C_GID} ..."
  if [ -n "$(grep ^i2c: /etc/group)" ]; then
    sed -i "s/^i2c\:.*/i2c\:x\:${I2C_GID}/" /etc/group
  else
    groupadd --force --gid ${I2C_GID} --non-unique i2c 2>&1>/dev/null
  fi
  adduser --quiet fhem i2c 2>&1>/dev/null
  find /dev/ -name "i2c-*" -exec chown --recursive --quiet --no-dereference .i2c {} \;
  (( i++ ))
fi

echo "$i. Updating /etc/sudoers.d/fhem-docker ..."
echo "# Auto-generated during container start" > /etc/sudoers.d/fhem-docker

# required by modules
echo "fhem ALL=(ALL) NOPASSWD: /usr/bin/nmap" >> /etc/sudoers.d/fhem-docker

# Allow updates
echo "fhem ALL=(ALL) NOPASSWD: /usr/bin/apt-get -q update" >> /etc/sudoers.d/fhem-docker
echo "fhem ALL=(ALL) NOPASSWD: /usr/bin/apt-get -s -q -V upgrade" >> /etc/sudoers.d/fhem-docker
echo "fhem ALL=(ALL) NOPASSWD: /usr/bin/apt-get -y -q -V upgrade" >> /etc/sudoers.d/fhem-docker
echo "fhem ALL=(ALL) NOPASSWD: /usr/bin/apt-get -y -q -V dist-upgrade" >> /etc/sudoers.d/fhem-docker
echo "fhem ALL=(ALL) NOPASSWD:SETENV: /usr/bin/npm update *" >> /etc/sudoers.d/fhem-docker

# Allow installation of new packages
echo "fhem ALL=(ALL) NOPASSWD:SETENV: /usr/local/bin/cpanm *" >> /etc/sudoers.d/fhem-docker
echo "fhem ALL=(ALL) NOPASSWD: /usr/bin/apt-get -y install *" >> /etc/sudoers.d/fhem-docker
echo "fhem ALL=(ALL) NOPASSWD:SETENV: /usr/bin/npm install *" >> /etc/sudoers.d/fhem-docker
echo "fhem ALL=(ALL) NOPASSWD:SETENV: /usr/bin/npm uninstall *" >> /etc/sudoers.d/fhem-docker

chmod 440 /etc/sudoers.d/fhem*
chown --quiet --no-dereference root:${FHEM_GID} /etc/sudoers.d/fhem* 2>&1>/dev/null
(( i++ ))

# SSH key: Ed25519
mkdir -p ${FHEM_DIR}/.ssh
if [ ! -s ${FHEM_DIR}/.ssh/id_ed25519 ]; then
  echo "$i. Generating SSH Ed25519 client certificate for user 'fhem' ..."
  rm -f ${FHEM_DIR}/.ssh/id_ed25519*
  ssh-keygen -t ed25519 -f ${FHEM_DIR}/.ssh/id_ed25519 -q -N "" -o -a 100
  sed -i "s/root@.*/fhem@fhem-docker/" ${FHEM_DIR}/.ssh/id_ed25519.pub
  (( i++ ))
fi

# SSH key: RSA
if [ ! -s ${FHEM_DIR}/.ssh/id_rsa ]; then
  echo "$i. Generating SSH RSA client certificate for user 'fhem' ..."
  rm -f ${FHEM_DIR}/.ssh/id_rsa*
  ssh-keygen -t rsa -b 4096 -f ${FHEM_DIR}/.ssh/id_rsa -q -N "" -o -a 100
  sed -i "s/root@.*/fhem@fhem-docker/" ${FHEM_DIR}/.ssh/id_rsa.pub
  (( i++ ))
fi

# SSH client hardening
if [ ! -f ${FHEM_DIR}/.ssh/config ]; then
  echo "$i. Generating SSH client configuration for user 'fhem' ..."
echo "IdentityFile ~/.ssh/id_ed25519
IdentityFile ~/.ssh/id_rsa

Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
HostKeyAlgorithms ssh-ed25519,ssh-rsa
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-256,hmac-sha2-512,umac-128-etm@openssh.com
" > ${FHEM_DIR}/.ssh/config
  (( i++ ))
fi

# Adding local hosts file
if [ -z $(dig +short -t a gateway.docker.internal.) ]; then
  echo "$i. Adding gateway.docker.internal to /etc/hosts ..."
  if [ -n "${DOCKER_GW}" ]; then
    grep -q -E "gateway\.docker\.internal" /etc/hosts || echo -e "${DOCKER_GW}\tgateway.docker.internal" >> /etc/hosts
  fi
  (( i++ ))
fi
if [ -z $(dig +short -t a host.docker.internal.) ]; then
  echo "$i. Adding host.docker.internal to /etc/hosts ..."
  if [ -n "${DOCKER_HOST}" ]; then
    grep -q -E "host\.docker\.internal" /etc/hosts || echo -e "${DOCKER_HOST}\thost.docker.internal" >> /etc/hosts
  else
    grep -q -E "host\.docker\.internal" /etc/hosts || echo -e "127.0.127.2\thost.docker.internal" >> /etc/hosts
  fi
  (( i++ ))
fi

# Key pinning for Docker host
echo "$i. Pre-authorizing SSH to Docker host for user 'fhem' ..."
touch ${FHEM_DIR}/.ssh/known_hosts
grep -v -E "^host.docker.internal" ${FHEM_DIR}/.ssh/known_hosts | grep -v -E "^gateway.docker.internal" > ${FHEM_DIR}/.ssh/known_hosts.tmp
ssh-keyscan -t ed25519 host.docker.internal 2>/dev/null >> ${FHEM_DIR}/.ssh/known_hosts.tmp
ssh-keyscan -t rsa host.docker.internal 2>/dev/null >> ${FHEM_DIR}/.ssh/known_hosts.tmp
mv -f ${FHEM_DIR}/.ssh/known_hosts.tmp ${FHEM_DIR}/.ssh/known_hosts
(( i++ ))

# SSH key pinning
echo "$i. Updating SSH key pinning and SSH client permissions for user 'fhem' ..."
cat ${FHEM_DIR}/.ssh/known_hosts /ssh_known_hosts.txt | grep -v ^# | sort -u -k1,2 > ${FHEM_DIR}/.ssh/known_hosts.tmp
mv -f ${FHEM_DIR}/.ssh/known_hosts.tmp ${FHEM_DIR}/.ssh/known_hosts
chown -R fhem.fhem ${FHEM_DIR}/.ssh/
chmod 600 ${FHEM_DIR}/.ssh/id_ed25519 ${FHEM_DIR}/.ssh/id_rsa
chmod 644 ${FHEM_DIR}/.ssh/id_ed25519.pub ${FHEM_DIR}/.ssh/id_rsa.pub
(( i++ ))

# Function to print FHEM log in incremental steps to the docker log.
[ -s "$( date +"${LOGFILE}" )" ] && OLDLINES=$( wc -l < "$( date +"${LOGFILE}" )" ) || OLDLINES=0
NEWLINES=${OLDLINES}
FOUND=false
function PrintNewLines {
  if [ -s "$( date +"${LOGFILE}" )" ]; then
  	NEWLINES=$(wc -l < "$(date +"${LOGFILE}")")
  	(( OLDLINES <= NEWLINES )) && LINES=$(( NEWLINES - OLDLINES )) || LINES=${NEWLINES}
  	tail -n "${LINES}" "$(date +"${LOGFILE}")"
  	[ -n "$1" ] && grep -q "$1" <(tail -n "$LINES" "$(date +"${LOGFILE}")") && FOUND=true || FOUND=false
  	OLDLINES=${NEWLINES}
  fi
}

# Docker stop signal handler
function StopFHEM {
	echo -e '\n\nSIGTERM signal received, sending "shutdown" command to FHEM!\n'
	PID=$(<"${PIDFILE}")
  su - fhem -c "cd "${FHEM_DIR}"; perl fhem.pl 7072 shutdown"
	echo -e 'Waiting for FHEM process to terminate before stopping container:\n'

  # Wait for FHEM to complete shutdown
	until $FOUND; do
		sleep $SLEEPINTERVAL
      		PrintNewLines "Server shutdown"
	done

  # Wait for FHEM normal process exit
	while ( kill -0 "$PID" 2> /dev/null ); do
		sleep $SLEEPINTERVAL
	done
	PrintNewLines
	echo 'FHEM process terminated, stopping container. Bye!'
	exit 0
}

# Start FHEM
function StartFHEM {
  echo -e '\n\n'

  if [ -s /pre-start.sh ]; then
    echo "Running pre-start script ..."
    chmod 755 /pre-start.sh
    /pre-start.sh
  fi

  # Update system environment
  #

  echo -n 'Preparing configuration ...'

  if [ "${CONFIGTYPE}" == "configDB" ]; then
    echo ' skipped (detected configDB)'
    echo ' HINT: Make sure to have your FHEM configuration properly prepared for compatibility with this Docker Image _before_ using configDB !'
  else
    echo ''

    # Mandatory
    [ -z "$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P '^define .+ DockerImageInfo.*')" ] && echo "define DockerImageInfo DockerImageInfo" >> ${FHEM_DIR}/${CONFIGTYPE}
    sed -i "s,attr global nofork.*,attr global nofork 0," ${FHEM_DIR}/${CONFIGTYPE}
    [ -z "$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P '^attr global nofork')" ] && echo "attr global nofork 0" >> ${FHEM_DIR}/${CONFIGTYPE}
    sed -i "s,attr global updateInBackground.*,attr global updateInBackground 1," ${FHEM_DIR}/${CONFIGTYPE}
    [ -z "$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P '^attr global updateInBackground')" ] && echo "attr global updateInBackground 1" >> ${FHEM_DIR}/${CONFIGTYPE}
    sed -i "s,attr global logfile.*,attr global logfile ${LOGFILE#${FHEM_DIR}/}," ${FHEM_DIR}/${CONFIGTYPE}
    [ -z "$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P '^attr global logfile')" ] && echo "attr global logfile ${LOGFILE#${FHEM_DIR}/}" >> ${FHEM_DIR}/${CONFIGTYPE}
    sed -i "s,attr global pidfilename.*,attr global pidfilename ${PIDFILE#${FHEM_DIR}/}," ${FHEM_DIR}/${CONFIGTYPE}
    [ -z "$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P '^attr global pidfilename')" ] && echo "attr global pidfilename ${PIDFILE#${FHEM_DIR}/}" >> ${FHEM_DIR}/${CONFIGTYPE}

    ## Find Telnet access details
    if [ -z "$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P "^define .* telnet ${TELNETPORT}")" ]; then
      CUSTOMPORT="$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P '^define telnetPort telnet ' | cut -d ' ' -f 4)"
      if [ -z "${CUSTOMPORT}"]; then
        echo "define telnetPort telnet ${TELNETPORT}" >> ${FHEM_DIR}/${CONFIGTYPE}
      else
        TELNETPORT=${CUSTOMPORT}
      fi
    fi
    TELNETDEV="$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P "^define .* telnet ${TELNETPORT}" | cut -d " " -f 2)"
    TELNETALLOWEDDEV="$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P "^attr .* validFor .*${TELNETDEV}.*" | cut -d " " -f 2)"

    ## Enforce local telnet access w/o password
    if [ -n "$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P "^attr ${TELNETALLOWEDDEV} password.*")" ]; then
      if [ -n "$(cat ${FHEM_DIR}/${CONFIGTYPE} | grep -P "^attr ${TELNETALLOWEDDEV} globalpassword.*")" ]; then
        echo "  - Removed local password from Telnet allowed device '${TELNETALLOWEDDEV}'"
        sed -i "/attr ${TELNETALLOWEDDEV} password/d" ${FHEM_DIR}/${CONFIGTYPE}
      else
        echo "  - Re-defined local password of Telnet allowed device '${TELNETALLOWEDDEV}' to global password"
        sed -i "s,attr ${TELNETALLOWEDDEV} password,attr ${TELNETALLOWEDDEV} globalpassword," ${FHEM_DIR}/${CONFIGTYPE}
      fi
    fi

    # Optional
    sed -i "s,attr global dnsServer.*,attr global dnsServer ${DNS}," ${FHEM_DIR}/${CONFIGTYPE}
  fi

  echo -n -e "\nStarting FHEM ...\n"
  trap "StopFHEM" SIGTERM
  su - fhem -c "cd "${FHEM_DIR}"; perl fhem.pl "$CONFIGTYPE""
  RET=$?

  # If process was unable to restart,
  # exit the container with error state
  if [ ${RET} -ne 0 ]; then
    echo "Unable to start FHEM process - errorcode $RET"
    exit ${RET}
  fi

  # Wait for FHEM to start up
  until $FOUND; do
  	sleep $SLEEPINTERVAL
        	PrintNewLines "Server started"
  done

  if [ -s /post-start.sh ]; then
    echo "Running post-start script ..."
    chmod 755 /post-start.sh
    /post-start.sh
  fi

  PrintNewLines
}

StartFHEM

# Monitor FHEM during runtime
while true; do

  # FHEM isn't running
	if [ ! -s "$PIDFILE" ] || ! kill -0 "$(<"$PIDFILE")" 2>&1 >/dev/null; then
		PrintNewLines
		COUNTDOWN="$TIMEOUT"
		echo -ne "\n\nAbrupt daemon termination, starting $COUNTDOWN""s countdown ..."
		while ( [ ! -s "$PIDFILE" ] || ! kill -0 "$(<"$PIDFILE")" 2>&1 >/dev/null ) && (( COUNTDOWN > 0 )); do
			echo -n " $COUNTDOWN"
			(( COUNTDOWN-- ))
			sleep 1
		done

    # FHEM didn't reappear
    if [ ! -s "$PIDFILE" ] || ! kill -0 "$(<"$PIDFILE")" 2>&1 >/dev/null; then

      # Container should be stopped
      if [ "$RESTART" == "0" ]; then
        echo -e ' 0\nStopping Container. Bye!\n'
		    exit 1

      # Automatic restart is enabled
      else
        echo -e ' 0\nAutomatic restart ...\n'

        # Cleanup
        if [ -s "$PIDFILE" ]; then
           kill -9 "$(<"$PIDFILE")" 2>&1>/dev/null
           rm -f "$PIDFILE"
        fi

        StartFHEM
      fi

    # FHEM reappeared
		else
			echo -e '\nFHEM process reappeared ...\n'
		fi
	fi

  # Printing log lines in intervalls
	PrintNewLines
	sleep $SLEEPINTERVAL
done
