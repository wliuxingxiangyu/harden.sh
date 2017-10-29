#!/bin/bash
################################################################################
#
# harden.sh -- https://github.com/pyllyukko/harden.sh
#
################################################################################
if [ ${BASH_VERSINFO[0]} -ne 4 ]
then
  echo -e "error: bash version != 4, this script might not work properly!" 1>&2
  echo    "       you can bypass this check by commenting out lines $[${LINENO}-2]-$[${LINENO}+2]." 1>&2
  exit 1
fi
shopt -s extglob
set -u
export PATH="/usr/sbin:/sbin:/usr/bin:/bin"
for PROGRAM in \
  awk     \
  cat     \
  cp      \
  id      \
  usermod \
  grpck   \
  chmod   \
  chown   \
  date    \
  gawk    \
  getent  \
  grep    \
  bzgrep  \
  fgrep   \
  ln      \
  mkdir   \
  mv      \
  openssl \
  patch   \
  rm      \
  sed     \
  shred   \
  mktemp  \
  tee     \
  diff    \
  stat    \
  realpath
do
  if ! hash "${PROGRAM}" 2>/dev/null
  then
    printf "[-] error: command not found in PATH: %s\n" "${PROGRAM}" >&2
    exit 1
  fi
done
unset PROGRAM
# the rc.modules* should match at least the following:
#   - rc.modules.local
#   - rc.modules-2.6.33.4
#   - rc.modules-2.6.33.4-smp
CWD=$( realpath $( dirname "${0}" ) )
for file in sysstat.sh utils.sh pam.sh apparmor.sh gpg.sh banners.sh
do
  . ${CWD}/libexec/${file} || {
    echo "[-] couldn't find libexec/${file}" 1>&2
    exit 1
  }
done
unset file
SERVICES_WHITELIST=(
  /etc/rc.d/rc.0
  /etc/rc.d/rc.4
  /etc/rc.d/rc.6
  /etc/rc.d/rc.K
  /etc/rc.d/rc.M
  /etc/rc.d/rc.S
  /etc/rc.d/rc.acpid
  /etc/rc.d/rc.firewall
  /etc/rc.d/rc.font
  /etc/rc.d/rc.loop
  /etc/rc.d/rc.inet1
  /etc/rc.d/rc.inet2
  /etc/rc.d/rc.keymap
  /etc/rc.d/rc.local
  /etc/rc.d/rc.local_shutdown
  /etc/rc.d/rc.modules
  /etc/rc.d/rc.modules-+([0-9.])?(-smp)
  /etc/rc.d/rc.modules.local
  /etc/rc.d/rc.netdevice
  /etc/rc.d/rc.sshd
  /etc/rc.d/rc.syslog
  "${SA_RC}"
  /etc/rc.d/rc.udev
  /etc/rc.d/rc.ntpd
  /etc/rc.d/rc.mcelog
  /etc/rc.d/rc.sysvinit
  # SBo:
  /etc/rc.d/rc.clamav
  /etc/rc.d/rc.snort
  /etc/rc.d/rc.auditd
)
#declare -ra LOG_FILES=(
#  btmp
#  cron*
#  debug*
#  dmesg
#  faillog
#  lastlog
#  maillog*
#  messages*
#  secure*
#  spooler*
#  syslog*
#  wtmp
#  xferlog
#)

# PATCHES

#declare -r APACHE_PATCH_VERSION="2.4.3-20120929-1"
declare -r APACHE_PATCH_FILE="apache_harden.patch"
declare -r SENDMAIL_PATCH_FILE="sendmail_harden.patch"
declare -r SUDOERS_PATCH_VERSION="1.8.12"
declare -r SUDOERS_PATCH_FILE="sudoers-${SUDOERS_PATCH_VERSION}.patch"
# OpenSSH configs differ between versions, so we need to have quite version
# specific patches, it also isn't Slackware version dependent, so we need to
# try to detect it.
SSH_VERSION=$( ssh -V 2>&1 | sed 's/^OpenSSH_\([^,]\+\),.*$/\1/' )
case "${SSH_VERSION}" in
  "6.3p1")	SSH_PATCH_FILE="ssh_harden-6.3p1.patch" ;;
  "6.7p1")	SSH_PATCH_FILE="ssh_harden-6.7p1.patch" ;;
  "7.1p1")	SSH_PATCH_FILE="ssh_harden-7.1p1.patch" ;;
  *)		SSH_PATCH_FILE="ssh_harden-6.3p1.patch" ;;
esac

# /PATCHES

# determine distro
if [ -f /etc/os-release ]
then
  DISTRO=$( sed -n '/^ID=/s/^ID=//p' /etc/os-release )
fi
declare -r SLACKWARE_VERSION=$( sed 's/^.*[[:space:]]\([0-9]\+\.[0-9]\+\).*$/\1/' /etc/slackware-version 2>/dev/null )
declare -r ETC_PATCH_FILE="harden_etc-${SLACKWARE_VERSION}.patch"
# these are not declared as integers cause then the ${ ... :-DEFAULT } syntax won't work(?!)
declare -r UID_MIN=$(		awk '/^UID_MIN/{print$2}'	/etc/login.defs 2>/dev/null )
declare -r UID_MAX=$(		awk '/^UID_MAX/{print$2}'	/etc/login.defs 2>/dev/null )
declare -r SYS_UID_MAX=$(	awk '/^SYS_UID_MAX/{print$2}'	/etc/login.defs 2>/dev/null )
declare -r WWWROOT="/var/www"
declare -i ETC_CHANGED=0
declare -r SENDMAIL_CF_DIR="/usr/share/sendmail/cf/cf"
declare -r SENDMAIL_CONF_PREFIX="sendmail-slackware"
declare -r RBINDIR="/usr/local/rbin"
declare -r INETDCONF="/etc/inetd.conf"
declare -r CADIR="/usr/share/ca-certificates/local"
declare -r SKS_CA="sks-keyservers.netCA.pem"
declare -a NAMES=( $( cut -d: -f1 /etc/passwd ) )
auditPATH='/etc/audit'
logdir=$( mktemp -p /tmp -d harden.sh.XXXXXX )
declare -rA grsec_groups=(
  ["grsec_proc"]=1001
  ["grsec_sockets"]=1002
  ["grsec_socketc"]=1003
  ["grsec_socketall"]=1004
  ["grsec_tpe"]=1005
  ["grsec_symlinkown"]=1006
  ["grsec_audit"]=1007
)
declare -rA PASSWORD_POLICIES=(
  ["PASS_MAX_DAYS"]=365
  ["PASS_MIN_DAYS"]=7
  ["PASS_WARN_AGE"]=30
  ["ENCRYPT_METHOD"]="SHA512"
  ["SHA_CRYPT_MIN_ROUNDS"]=500000
  ["UMASK"]="077"
)
password_inactive=-1
declare -rA PWQUALITY_SETTINGS=(
  ["minlen"]="14"
  ["dcredit"]="-1"
  ["ucredit"]="-1"
  ["ocredit"]="-1"
  ["lcredit"]="-1"
)
# TODO:
#   - PubkeyAcceptedKeyTypes
#   - HostKeyAlgorithms
#   - Ciphers
#   - MACs
#   - KEX
declare -rA SSHD_CONFIG=(
  # from hardening guides
  ["Protocol"]=2
  ["LogLevel"]="INFO"
  ["X11Forwarding"]="no"
  ["MaxAuthTries"]=4
  ["IgnoreRhosts"]="yes"
  ["HostbasedAuthentication"]="no"
  ["PermitRootLogin"]="no"
  ["PermitEmptyPasswords"]="no"
  ["PermitUserEnvironment"]="no"
  # ciphers
  # mac
  ["ClientAliveInterval"]=300
  ["ClientAliveCountMax"]=0
  ["LoginGraceTime"]=60

  # custom
  ["PubkeyAuthentication"]="yes"
  ["UseLogin"]="no"
  ["StrictModes"]="yes"
  ["PrintLastLog"]="yes"
  ["UsePrivilegeSeparation"]="sandbox"
  # see http://www.openssh.com/txt/draft-miller-secsh-compression-delayed-00.txt
  ["Compression"]="delayed"
  ["AllowTcpForwarding"]="no"
  ["FingerprintHash"]="sha256"
)
# TODO: http://wiki.apparmor.net/index.php/Distro_debian#Tuning_logs
declare -rA AUDITD_CONFIG=(
  ["space_left_action"]="email"
  ["action_mail_acct"]="root"
  ["max_log_file_action"]="keep_logs"
)
declare -rA LIGHTDM_CONFIG=(
  ["greeter-hide-users"]="true"
  # https://freedesktop.org/wiki/Software/LightDM/CommonConfiguration/#disablingguestlogin
  ["allow-guest"]="false"
)
declare -rA FILE_PERMS=(
  ["/boot/grub/grub.cfg"]="og-rwx"
  ["/etc/ssh/sshd_config"]="600"
)

# NOLOGIN(8): "It is intended as a replacement shell field for accounts that have been disabled."
# Slackware default location:
if [ -x /sbin/nologin ]
then
  DENY_SHELL="/sbin/nologin"
# Debian default location:
elif [ -x /usr/sbin/nologin ]
then
  DENY_SHELL="/usr/sbin/nologin"
else
  echo "[-] warning: can't find nologin!" 1>&2
  DENY_SHELL=
fi
# man FAILLOG(8)
declare -i FAILURE_LIMIT=5
declare -r CERTS_DIR="/etc/ssl/certs"

# from CIS 2.1 Disable Standard Services
declare -a INETD_SERVICES=(echo discard daytime chargen time ftp telnet comsat shell login exec talk ntalk klogin eklogin kshell krbupdate kpasswd pop imap uucp tftp bootps finger systat netstat auth netbios swat rstatd rusersd walld)

# ...plus some extras
INETD_SERVICES+=(pop3 imap2 netbios-ssn netbios-ns)

# from CIS Apache HTTP Server 2.4 Benchmark v1.1.0 - 12-03-2013
# 1.2.3-8
declare -a apache_disable_modules_list=(
  'dav_'
  'status_module'
  'autoindex_module'
  'proxy_'
  'userdir_module'
  'info_module'
)
declare -r ARCH=$( /bin/uname -m )
case "${MACHTYPE%%-*}" in
  "x86_64")	SLACKWARE="slackware64"	;;
  i?86)		SLACKWARE="slackware"	;;
  # TODO: arm
esac
if [ -n "${SLACKWARE_VERSION}" ]
then
  MANIFEST_DIR="${CWD}/manifests/${SLACKWARE}-${SLACKWARE_VERSION}"
fi
################################################################################
function read_password_policy() {
  PASS_MIN_DAYS=$( awk '/^PASS_MIN_DAYS/{print$2}' /etc/login.defs 2>/dev/null )
  PASS_MAX_DAYS=$( awk '/^PASS_MAX_DAYS/{print$2}' /etc/login.defs 2>/dev/null )
  PASS_WARN_AGE=$( awk '/^PASS_WARN_AGE/{print$2}' /etc/login.defs 2>/dev/null )
  if [ -z "${PASS_MIN_DAYS}" -o -z "${PASS_MAX_DAYS}" -o -z "${PASS_WARN_AGE}" ]
  then
    echo "[-] warning: couldn't determine PASS_* from /etc/login.defs"
    return 1
  fi
} # read_password_policy()
################################################################################
function disable_inetd_services() {
  # CIS 2.1 Disable Standard Services
  local SERVICE

  cat 0<<-EOF
	
	disabling inetd services
	------------------------
EOF

  if [ ! -f "${INETDCONF}" ]
  then
    echo "inetd conf file not found!" 1>&2
    return 0
  fi

  if [ ! -f "${INETDCONF}.original" ]
  then
    cp -v "${INETDCONF}" "${INETDCONF}.original"
  fi

  echo -n "modifying ${INETDCONF} (${#INETD_SERVICES[*]} services)"
  for SERVICE in ${INETD_SERVICES[*]}
  do
    sed -i 's/^\('"${SERVICE}"'\)/\#\1/' "${INETDCONF}"
    echo -n '.'
  done
  echo -n $'\n'

  return
} # disable_inetd_services()
################################################################################
function create_environment_for_restricted_shell () {
  local PRG

  cat 0<<-EOF
	
	populating ${RBINDIR}
	-----------${RBINDIR//?/-}
EOF

  if [ ! -d "${RBINDIR}" ]
  then
    mkdir -pv "${RBINDIR}"
  fi
  {
    chown -c root:root	"${RBINDIR}"
    chmod -c 755	"${RBINDIR}"
  } | tee -a "${logdir}/file_perms.txt"

  #rm -v "${RBINDIR}/"*

  pushd "${RBINDIR}" 1>/dev/null || return 1

  for PRG in /bin/{cat,cp,df,du,id,ls,mkdir,mv,uname,who} /usr/bin/{chage,passwd,printenv,uptime}
  do
    ln -sv ${PRG}
  done
  ln -sv /usr/bin/vim	rvim
  ln -sv /usr/bin/view	rview

  popd 1>/dev/null

  return
} # create_environment_for_restricted_shell()
################################################################################
function lock_system_accounts() {
  local NAME
  local uid
  local password_status

  cat 0<<-EOF
	
	locking system accounts
	-----------------------
EOF
  # CIS 8.1 Block System Accounts (modified)
  # CIS 3.4 Disable Standard Boot Services (modified) (the user accounts part)
  #
  # NOTE: according to CIS (3.13 Only Enable SQL Server Processes If Absolutely Necessary & 8.1 Block System Accounts)
  #       mysql user account needs to have bash as it's shell.
  #
  # NOTE:
  #   - this should be run periodically
  #   - 29.8.2012: added expire as suggested in passwd(1)
  #
  # TODO: find out the details about mysql's shell!!
  for NAME in ${NAMES[*]}
  do
    uid=$( id -u ${NAME} )
    # as the NAMES array is populated in the beginning of the script, some user
    # accounts might have been hardened away already at this point.
    if [ -z "${uid}" ]
    then
      continue
    fi
    if [ ${uid} -le ${SYS_UID_MAX:-999} ] && \
      [ ${NAME} != 'root' ] && \
      [ ${NAME} != 'Debian-gdm' ] && \
      [ ${NAME} != 'daemon' ]
    then
      printf "%-17s (UID=%s)\n" "${NAME}" "${uid}"
      crontab -l -u "${NAME}" 2>&1 | grep -q "^\(no crontab for\|The user \S\+ cannot use this program (crontab)\)"
      if [ ${PIPESTATUS[1]} -ne 0 ]
      then
        echo "[-] WARNING: the user \`${NAME}' has some cronjobs! should it be so?" 1>&2
      fi
      password_status=$( /usr/bin/passwd -S "${NAME}" | awk '{print$2}' )
      if [ "${password_status}" != "L" ]
      then
        echo "[-] WARNING: the account \`${NAME}' is not locked properly!" 1>&2
      fi
      /usr/sbin/usermod -e 1970-01-02 -L -s "${DENY_SHELL}" "${NAME}"
    fi
  done
} # lock_system_accounts()
################################################################################
function user_accounts() {
  # NOTE: http://refspecs.freestandards.org/LSB_4.1.0/LSB-Core-generic/LSB-Core-generic/usernames.html
  #
  # NOTE: http://www.redhat.com/archives/nahant-list/2007-March/msg00163.html (good thread about halt & shutdown accounts)
  #
  # TODO: groups (or are they even necessary?)

  local group

  cat 0<<-EOF
	
	modifying/hardening current user accounts
	-----------------------------------------
EOF

  if [ ! -x "${DENY_SHELL}" ]
  then
    echo "[-] error: invalid \$DENY_SHELL!" 1>&2
    return 1
  fi

  # CUSTOM

  # change the defaults. this will update /etc/default/useradd.
  # this makes it so, that when a password of a user expires, the account is
  # locked after 35 days and the user cannot login anymore.
  #
  # WARNING: you don't want to set the EXPIRE (-e), since it's an absolute
  # date, and not relative. it's too easy to create accounts that are already
  # locked.
  #
  # see http://tldp.org/HOWTO/Shadow-Password-HOWTO-7.html#ss7.1
  useradd -D -f ${password_inactive}

  # modify adduser to use 700 as newly created home dirs permission
  sed -i 's/^defchmod=[0-9]\+\(.*\)$/defchmod=700\1/' /usr/sbin/adduser

  lock_system_accounts

  configure_password_policy_for_existing_users

  # from README.privsep
  # another less tiger warning (pass016w)
  /usr/sbin/usermod -c 'sshd privsep' -d /var/empty sshd

  user_home_directories_permissions


  # CUSTOM

  #
  # See GPASSWD(1): "Notes about group passwords"
  #
  # remove daemon from adm group, since we use adm group for log reading.
  # default members in Slack14.0:
  #   adm:x:4:root,adm,daemon
  #usermod -G daemon daemon
  gpasswd -d daemon adm

  # restrict adm group
  #gpasswd -R adm

  echo "[+] creating groups for grsecurity"
  for group in ${!grsec_groups[*]}
  do
    groupadd -g ${grsec_groups[${group}]} ${group}
  done

  # this should create the missing entries to /etc/gshadow
  cat 0<<-EOF
	
	### fixing gshadow
EOF
  if [ -x /usr/sbin/grpck ]
  then
    /usr/bin/yes | /usr/sbin/grpck
  else
    echo "[-] WARNING: grpck not found!" 1>&2
  fi

  set_failure_limits

  create_ftpusers

  restrict_cron

  return 0
} # user_accounts()
################################################################################
function configure_password_policy_for_existing_users() {
  local NAME
  local uid
  # CIS 8.3 Set Account Expiration Parameters On Active Accounts
  cat 0<<-EOF
	
	configuring password policies for existing users
	------------------------------------------------
EOF
  read_password_policy
  for NAME in ${NAMES[*]}
  do
    uid=$( id -u $NAME )
    if [ -z "${uid}" ]
    then
      continue
    fi
    if [ $uid -ge ${UID_MIN:-1000} ] && [ $uid -le ${UID_MAX:-60000} ]
    then
      echo "  UID ${uid}"
      chage -m ${PASS_MIN_DAYS:-7} -M ${PASS_MAX_DAYS:-365} -W ${PASS_WARN_AGE:-30} -I ${password_inactive} $NAME
    fi
  done
} # configure_password_policy_for_existing_users()
################################################################################
function restrict_cron() {
  cat 0<<-EOF
	
	restricting use of cron & at
	----------------------------
EOF
  # CIS 7.5 Restrict at/cron To Authorized Users
  #
  # NOTE: Dillon's cron does not support /etc/cron.{allow,deny}
  #
  # NOTE: if both /etc/cron.{allow,deny} are missing, tiger reports this:
  #       --WARN-- [cron005w] Use of cron is not restricted
  #
  # "Don't allow anyone to use at."
  #
  # AT.ALLOW(5) & AT(1): "If the file /etc/at.allow exists, only usernames mentioned in it are allowed to use at."
  #
  # Slackware's at package creates /etc/at.deny by default, which has blacklisted users. so we're switching
  # from blacklist to (empty) whitelist.
  #
  # TODO: check whether debian, red hat etc. bring empty /etc/at.deny with the package
  if [ -s "/etc/at.deny" ] && [ ! -f "/etc/at.allow" ]
  then
    echo "[+] restricting the use of at"
    rm -v		/etc/at.deny
    /usr/bin/touch	/etc/at.allow
    {
      chown -c root:daemon	/etc/at.allow
      chmod -c 640		/etc/at.allow
    } | tee -a "${logdir}/file_perms.txt"
  fi

  echo "[+] restricting the use of cron"
  # dcron
  if /usr/sbin/crond -h 2>/dev/null | grep -q ^dillon
  then
    {
      # somewhere along the lines of CIS 7.5 Restrict at/cron To Authorized Users
      #
      # the dcron's README describes that the use should be limited by a
      # designated group (CRONTAB_GROUP) as follows:
      #   -rwx------  0 root   root    32232 Jan  6 18:58 /usr/local/sbin/crond
      #   -rwsr-x---  0 root   wheel   15288 Jan  6 18:58 /usr/local/bin/crontab
      # NOTE: alien uses the wheel group here: http://alien.slackbook.org/dokuwiki/doku.php?id=linux:admin
      /usr/bin/chmod -c 700	/usr/sbin/crond
      chgrp -c wheel		/usr/bin/crontab
      chmod -c 4710		/usr/bin/crontab
      # this line disables cron from everyone else but root:
      #/usr/bin/chmod -c u-s		/usr/bin/crontab
    } | tee -a "${logdir}/file_perms.txt"
  else
    rm -v		/etc/cron.deny
    /usr/bin/touch	/etc/cron.allow
    if getent group crontab 1>/dev/null
    then
      {
	chown -c root:crontab	/etc/cron.allow
	chmod -c 640		/etc/cron.allow
      } | tee -a "${logdir}/file_perms.txt"
    else
      chmod -c og-rwx /etc/cron.allow | tee -a "${logdir}/file_perms.txt"
    fi
  fi
  echo "[+] restricting /etc/cron{tab,.hourly,.daily,.weekly,.monthly,.d}"
  chmod -c og-rwx /etc/cron{tab,.hourly,.daily,.weekly,.monthly,.d} | tee -a "${logdir}/file_perms.txt"

  return 0
} # restrict_cron()
################################################################################
function lock_account() {
  echo "[+] locking account \"${1}\""
  if [ -z "${1}" ]
  then
    echo "[-] error!" 1>&2
    return 1
  fi
  id -u "${1}" &>/dev/null
  if [ ${?} -ne 0 ]
  then
    echo "[-] no such user!" 1>&2
    return 1
  fi
  /usr/sbin/usermod -e 1970-01-02 -L -s "${DENY_SHELL}" "${1}"
  /usr/bin/crontab -d -u "${1}"
  killall -s SIGKILL -u "${1}" -v
  #gpasswd -d "${1}" users

  return 0
} # lock_account()
################################################################################
function create_additional_user_accounts() {
  # see http://slackbuilds.org/uid_gid.txt

  groupadd -g 206 -r privoxy
  useradd  -u 206 -g privoxy -e 1970-01-02 -M -d /dev/null -s ${DENY_SHELL} -r privoxy

  # this is also used by metasploit
  groupadd -g 209 -r postgres
  useradd  -u 209 -e 1970-01-02 -g 209 -s ${DENY_SHELL} -M -d /var/lib/pgsql -r postgres

  # http://slackbuilds.org/repository/14.0/system/clamav/
  groupadd -g 210 -r clamav
  useradd  -u 210 -e 1970-01-02 -M -d /var/lib/clamav -s ${DENY_SHELL} -g clamav -r clamav

  # ntop 212

  #groupadd -g 213 -r nagios
  #useradd -u 213 -d /dev/null -s /sbin/nologin -g nagios -r nagios
  #usermod -G nagios -a apache

  groupadd -g 220 -r tor
  useradd  -u 220 -g 220 -e 1970-01-02 -c "The Onion Router" -M -d /var/lib/tor -s ${DENY_SHELL} tor

  groupadd -g 234 -r kismet

  return
} # create_additional_user_accounts()
################################################################################
function restart_services() {
  # stuff that needs to be restarted or loaded after patching etc
  #
  # NOTE: at least the following services are not started this way:
  #       - process accounting
  #       - logoutd

  [ -f /etc/sysctl.conf ]	&&	/sbin/sysctl -p 	/etc/sysctl.conf
  [ -x /etc/rc.d/rc.syslog ]	&&	/etc/rc.d/rc.syslog	restart
  # TODO: this might kill your SSH connection
  #[ -x /etc/rc.d/rc.firewall ] &&	/etc/rc.d/rc.firewall	restart

  # TODO: enable after making the ssh patch
  #[ -x /etc/rc.d/rc.sshd ] &&		/etc/rc.d/rc.sshd	restart

  return 0
} # restart_services()
################################################################################
function check_and_patch() {
  # $1 = dir
  # $2 = patch file
  # $3 = p level
  # $4 = [reverse]
  local DIR_TO_PATCH="${1}"
  local PATCH_FILE="${CWD}/patches/${2}"
  local P="${3}"
  local -i GREP_RET
  local -i PATCH_RET
  local -i RET

  [ ! -d "${DIR_TO_PATCH}" ] && {
    echo "[-] error: directory \`${DIR_TO_PATCH}' does not exist!" 1>&2
    return 1
  }

  [ ! -f "${PATCH_FILE}" ] && {
    echo "[-] error: patch file \`${PATCH_FILE}' does not exist!" 1>&2
    return 1
  }
  #pushd "${1}" || return 1

  set +u
  if [ -n "${4}" ] && [ "${4}" = "reverse" ]
  then
    # this is the best i came up with to detect if the patch is already applied/reversed before actually applying/reversing it.
    # patch seems to return 0 in every case, so we'll have to use grep here.
    echo "${FUNCNAME}(): testing patch file \`${PATCH_FILE##*/}' with --dry-run"
    /usr/bin/patch -R -d "${DIR_TO_PATCH}" -t -p${P} --dry-run -i "${PATCH_FILE}" | /usr/bin/grep "^\(Unreversed patch detected\|The next patch, when reversed, would delete the file\)"
    PATCH_RET=${PIPESTATUS[0]} GREP_RET=${PIPESTATUS[1]}
    if [ ${PATCH_RET} -ne 0 ] || [ ${GREP_RET} -eq 0 ]
    then
      echo "[-] error: patch dry-run didn't work out, maybe the patch has already been reversed?" 1>&2
      return 1
    fi
    # if everything was ok, apply the patch
    echo "${FUNCNAME}(): DEBUG: patch would happen"
    /usr/bin/patch -R -d "${DIR_TO_PATCH}" -t -p${P} -i "${PATCH_FILE}" | tee -a "${logdir}/patches.txt"
    RET=${?}
  else
    echo "${FUNCNAME}(): testing patch file \`${PATCH_FILE##*/}' with --dry-run"
    # TODO: detect rej? "3 out of 4 hunks FAILED -- saving rejects to file php.ini.rej"
    /usr/bin/patch -d "${DIR_TO_PATCH}" -t -p${P} --dry-run -i "${PATCH_FILE}" | /usr/bin/grep "^\(The next patch would create the file\|Reversed (or previously applied) patch detected\)"
    PATCH_RET=${PIPESTATUS[0]} GREP_RET=${PIPESTATUS[1]}
    if [ ${PATCH_RET} -ne 0 ] || [ ${GREP_RET} -eq 0 ]
    then
      echo "[-] error: patch dry-run didn't work out, maybe the patch has already been applied?" 1>&2
      return 1
    fi
    echo "DEBUG: patch would happen"
    /usr/bin/patch -d "${DIR_TO_PATCH}" -t -p${P} -i "${PATCH_FILE}" | tee -a "${logdir}/patches.txt"
    RET=${?}
  fi
  set -u
  return ${RET}
}
################################################################################
function remove_packages() {
  # BIG FAT NOTE: make sure you don't actually need these!
  #               although, i tried to keep the list short.

  echo "${FUNCNAME}(): removing potentially dangerous packages"

  # TODO: if -x removepkg && apt-get stuff
  {
    # CIS 7.1 Disable rhosts Support
    /sbin/removepkg netkit-rsh 2>/dev/null

    # from system-hardening-10.2.txt (Misc Stuff -> Stuff to remove)
    #
    # NOTE: uucp comes with a bunch of SUID binaries, plus i think most people
    #       won't need it nowadays anyway.
    /sbin/removepkg uucp 2>/dev/null

    # remove the floppy package. get rid of the fdmount SUID binary.
    /sbin/removepkg floppy 2>/dev/null

    # TODO: remove xinetd package?
  } | tee -a "${logdir}/removed_packages.txt"

  return 0
} # remove_packages()
################################################################################
function harden_fstab() {
  # related info: http://wiki.centos.org/HowTos/OS_Protection#head-7e30c59c22152e9808c2e0b95ceec1382456d35c
  #
  # TODO (from shred man page):
  #   In the particular case of ext3 file systems, the above disclaimer
  #   Applies (and `shred' is thus of limited effectiveness) only in
  #   `data=journal' mode, which journals file data in addition to just
  #   Metadata. In both the `data=ordered' (default) and `data=writeback'
  #   Modes, `shred' works as usual.  Ext3 journaling modes can be changed by
  #   Adding the `data=something' option to the mount options for a
  #   Particular file system in the `/etc/fstab' file, as documented in the
  #   Mount man page (man mount).

  cat 0<<-EOF
	
	hardening mount options in fstab
	--------------------------------
EOF

  if [ ! -w /etc ]
  then
    echo "[-] error: /etc is not writable. are you sure you are root?" 1>&2
    return 1
  elif [ ! -f /etc/fstab ]
  then
    echo "[-] error: /etc/fstab doesn't exist?!?" 1>&2
    return 1
  fi
  make -f ${CWD}/Makefile /etc/fstab.new

  if [ -f /etc/fstab.new ]
  then
    echo "[+] /etc/fstab.new created"
  fi

  return ${?}
} # harden_fstab()
################################################################################
function file_permissions() {
  # NOTE: from SYSKLOGD(8):
  #   "Syslogd doesn't change the filemode of opened logfiles at any stage of process.  If a file is created it is world readable.
  #
  # TODO: chmod new log files also

  echo "${FUNCNAME}(): setting file permissions. note that this should be the last function to run."

  { # log everything to file_perms.txt
    # CIS 1.4 Enable System Accounting (applied)
    #
    # NOTE: sysstat was added to slackware at version 11.0
    #
    # NOTE: the etc patch should create the necessary cron entries under /etc/cron.d
    /usr/bin/chmod -c 700 "${SA_RC}"

    # CIS 3.3 Disable GUI Login If Possible (partly)
    /usr/bin/chown -c root:root	/etc/inittab
    /usr/bin/chmod -c 0600	/etc/inittab

    # CIS 4.1 Network Parameter Modifications (partly)
    #
    # NOTE: sysctl.conf should be created by the etc patch
    /usr/bin/chown -c root:root	/etc/sysctl.conf
    /usr/bin/chmod -c 0600	/etc/sysctl.conf

    ## CIS 5.3 Confirm Permissions On System Log Files (modified)
    ## NOTE: apache -> httpd
    pushd /var/log
    ###############################################################################
    ## Permissions for other log files in /var/log
    ###############################################################################
    ## NOTE: according to tiger, the permissions of wtmp should be 664
    /usr/bin/chmod -c o-rwx {b,w}tmp cron* debug* dmesg {last,fail}log maillog* messages* secure* spooler* syslog* xferlog

    ###############################################################################
    ##   directories in /var/log
    ###############################################################################
    #/usr/bin/chmod -c o-w httpd cups iptraf nfsd samba sa uucp

    ###############################################################################
    ##   contents of directories in /var/log
    ###############################################################################
    #/usr/bin/chmod -c o-rwx httpd/* cups/* iptraf/* nfsd/* samba/* sa/* uucp/*

    ###############################################################################
    ##   Slackware package management
    ###############################################################################
    ##
    ## NOTE: Nessus plugin 21745 triggers, if /var/log/packages is not readable
    /usr/bin/chmod -c o-w packages removed_{packages,scripts} scripts setup
    #/usr/bin/chmod -c o-rwx	packages/* removed_packages/* removed_scripts/* scripts/* setup/*

    ###############################################################################
    ## Permissions for group log files in /var/log
    ###############################################################################
    ## NOTE: removed wtmp from here, it is group (utmp) writable by default and there might be a good reason for that.
    /usr/bin/chmod -c g-wx btmp cron* debug* dmesg {last,fail}log maillog* messages* secure* spooler* syslog* xferlog

    ##   directories in /var/log
    #/usr/bin/chmod -c g-w httpd cups iptraf nfsd samba sa uucp

    ##   contents of directories in /var/log
    #/usr/bin/chmod -c g-wx httpd/* cups/* iptraf/* nfsd/* samba/* sa/* uucp/*

    ###############################################################################
    ## Permissions for owner
    ###############################################################################
    ##   log files in /var/log
    #/usr/bin/chmod u-x btmp cron* debug* dmesg faillog lastlog maillog* messages* secure* spooler* syslog* wtmp xferlog
    ##   contents of directories in /var/log
    ## NOTE: disabled, these directories might contain subdirectories so u-x doesn't make sense.
    ##/usr/bin/chmod u-x httpd/* cups/* iptraf/* nfsd/* samba/* sa/* uucp/*

    ##   Slackware package management
    ## NOTE: disabled, these directories might contain subdirectories so u-x doesn't make sense.
    ##/usr/bin/chmod u-x packages/* removed_packages/* removed_scripts/* scripts/* setup/*

    ## Change ownership
    ## NOTE: disabled, the ownerships should be correct.
    ##/usr/bin/chown -cR root:root .
    ##/usr/bin/chown -c uucp uucp
    ##/usr/bin/chgrp -c uucp uucp/*
    ##/usr/bin/chgrp -c utmp wtmpq

    if [ -d sudo-io ]
    then
      /usr/bin/chown -c root:root	sudo-io
      /usr/bin/chmod -c 700		sudo-io
    fi

    popd

    ## END OF CIS 5.3

    # CIS 6.3 Verify passwd, shadow, and group File Permissions (modified)

    # here's where CIS goes wrong, the permissions by default are:
    # -rw-r----- root/shadow     498 2009-03-08 22:01 etc/shadow.new
    # ...if we go changing that, xlock for instance goes bananas.
    # modified accordingly.
    #
    # then again, if there is no xlock or xscreensaver binaries in the system,
    # the perms could be root:root 0600.
    #
    # 9.10.2012: added gshadow to the list
    /usr/bin/chown -c root:root		/etc/passwd /etc/group
    /usr/bin/chmod -c 644		/etc/passwd /etc/group
    # NOTE: when using grsec's RBAC, if shadow is read-only passwd will require CAP_DAC_OVERRIDE
    /usr/bin/chown -c root:shadow	/etc/shadow /etc/gshadow
    /usr/bin/chmod -c 440		/etc/shadow /etc/gshadow

    # CIS 7.3 Create ftpusers Files
    /usr/bin/chown -c root:root		/etc/ftpusers
    /usr/bin/chmod -c 600		/etc/ftpusers

    # CIS 7.6 Restrict Permissions On crontab Files
    #
    # NOTE: Slackware doesn't have /etc/crontab, as it's ISC cron that has this
    #       file and not Dillon's cron
    if [ -f "/etc/crontab" ]
    then
      /usr/bin/chown -c root:root	/etc/crontab
      /usr/bin/chmod -c 400		/etc/crontab
    fi
    /usr/bin/chown -cR root:root	/var/spool/cron
    /usr/bin/chmod -cR go-rwx		/var/spool/cron

    # CIS 7.8 Restrict Root Logins To System Console
    # also Nessus cert_unix_checklist.audit "Permission and ownership check /etc/securetty"
    /usr/bin/chown -c root:root		/etc/securetty
    /usr/bin/chmod -c 400		/etc/securetty

    # CIS 7.9 Set LILO Password
    # - also suggested in system-hardening-10.2.txt
    # - also Tiger [boot01]
    /usr/bin/chown -c root:root		/etc/lilo.conf
    /usr/bin/chmod -c 600		/etc/lilo.conf

    # TODO: grub & general Debian support for this whole function

    # CIS 8.13 Limit Access To The Root Account From su
    /usr/bin/chown -c root:root		/etc/suauth
    /usr/bin/chmod -c 400		/etc/suauth

    # 8.7 User Home Directories Should Be Mode 750 or More Restrictive (modified)
    user_home_directories_permissions

    # CIS SN.2 Change Default Greeting String For sendmail
    #
    # i'm not sure about this one...
    #
    # ftp://ftp.slackware.com/pub/slackware/slackware-13.1/slackware/MANIFEST.bz2:
    # -rw-r--r-- root/root     60480 2010-04-24 11:44 etc/mail/sendmail.cf.new

    #/usr/bin/chown -c root:bin /etc/mail/sendmail.cf
    #/usr/bin/chmod -c 444 /etc/mail/sendmail.cf

    ##############################################################################
    # from Security Configuration Benchmark For Apache HTTP Server 2.2
    # Version 3.0.0 (CIS_Apache_HTTP_Server_Benchmark_v3.0.0)
    ##############################################################################

    # CIS 1.3.6 Core Dump Directory Security (Level 1, Scorable) (modified)
    #/usr/bin/chown -c root:apache	/var/log/httpd
    /usr/bin/chown -c root:adm		/var/log/httpd
    /usr/bin/chmod -c 750		/var/log/httpd

    ##############################################################################
    # from Nessus cert_unix_checklist.audit (Cert UNIX Security Checklist v2.0)
    # http://www.nessus.org/plugins/index.php?view=single&id=21157
    ##############################################################################

    # NOTE: netgroup comes with yptools
    # NOTE:
    #   login.defs might need to be readable:
    #     groupmems[7511]: cannot open login definitions /etc/login.defs [Permission denied]
    #     newgrp[4912]: cannot open login definitions /etc/login.defs [Permission denied]
    for FILE in \
      "/etc/hosts.equiv" \
      "${INETDCONF}" \
      "/etc/netgroup" \
      "/etc/login.defs" \
      "/etc/login.access"
    do
      [ ! -f "${FILE}" ] && continue
      /usr/bin/chown -c root:root	"${FILE}"
      /usr/bin/chmod -c 600		"${FILE}"
    done

    # Nessus Cert UNIX Security Checklist v2.0 "Permission and ownership check /var/adm/wtmp"
    # UTMP(5): "The  wtmp file records all logins and logouts."
    # LAST,LASTB(1): "Last  searches  back  through the file /var/log/wtmp (or the file designated by the -f flag)
    #                 and displays a list of all users logged in (and out) since that file was created."
    #
    # the default permissions in Slackware are as follows:
    # -rw-rw-r-- root/utmp         0 1994-02-10 19:01 var/log/wtmp.new
    #
    # wtmp offers simply too much detail over so long period of time.
    #
    # NOTE: in slackware 13.1 /var/adm is a symbolic link to /var/log
    #/usr/bin/chown -c root:utmp	/var/adm/wtmp
    #/usr/bin/chown -c root:root	/var/adm/wtmp[.-]*

    # CIS 5.3 handles the permissions, this file shouldn't be readable by all users. it contains sensitive information.
    # NOTE: 10.10.2012: CIS 5.3 commented out
    # rotated files... of course this should be done in logrotate.conf.
    /usr/bin/chmod -c o-rwx	/var/log/wtmp

    ##############################################################################
    # from system-hardening-10.2.txt:
    ##############################################################################

    # "The file may hold encryption keys in plain text."
    /usr/bin/chmod -c 600	/etc/rc.d/rc.wireless.conf

    # "The system startup scripts are world readable by default."
    /usr/bin/chmod -cR go-rwx /etc/rc.d/

    # "Remove the SUID or SGID bit from the following files"
    #
    # Slackware 14.0 default permissions:
    #   -rwsr-sr-x daemon/daemon 40616 2010-07-28 15:20 usr/bin/at
    #   -rws--x--x root/root     47199 2012-09-13 20:12 usr/bin/chfn
    #   -rws--x--x root/root     47197 2012-09-13 20:12 usr/bin/chsh
    #   -rws--x--x root/root     10096 2012-09-07 15:24 usr/bin/crontab
    #
    # NOTE: see CVE-2011-0721 for an example of why.
    #
    # NOTE: you can find all SUID/SGID binaries with "find / -type f \( -perm -04000 -o -perm -02000 \)"
    #/usr/bin/chmod -c ug-s	/usr/bin/at
    /usr/bin/chmod -c u-s	/usr/bin/chfn
    /usr/bin/chmod -c u-s	/usr/bin/chsh

    # NOTE: 9.10.2012: these could actually be needed.
    #/usr/bin/chmod -c u-s		/usr/bin/gpasswd
    #/usr/bin/chmod -c u-s		/usr/bin/newgrp

    # SSH-KEYSIGN(8):
    # ssh-keysign is disabled by default and can only be enabled in the global client
    # configuration file /etc/ssh/ssh_config by setting EnableSSHKeysign to ``yes''.
    #
    # if you use host based authentication with SSH, you probably need to comment
    # this out.
    #
    # also mentioned in the NSA guide section 2.2.3.4 "Find Unauthorized SUID/SGID System Executables"

    /usr/bin/chmod -c u-s		/usr/libexec/ssh-keysign

    ##############################################################################
    # end of system-hardening-10.2.txt
    ##############################################################################

    # from CIS RHEL guide (11.1 Configure and enable the auditd and sysstat services, if possible)
    chown -c root:root		$auditPATH/audit.rules
    chmod -c 0600		$auditPATH/audit.rules
    chmod -c 0600		$auditPATH/auditd.conf

    # CUSTOM STUFF BELOW

    # more SUID binaries:
    # notice that the uucp package is removed with remove_packages()
    /usr/bin/chmod -c u-s	/usr/bin/cu
    /usr/bin/chmod -c u-s	/usr/bin/uucp
    #/usr/bin/chmod -c u-s	/usr/bin/pkexec

    # from GROUPMEMS(8): "The groupmems executable should be in mode 2770 as user root and in group groups."
    # since we don't allow users to use it, make it 750.
    #chmod -c 750 /usr/sbin/groupmems

    # SSA:2011-101-01:
    if [ -u /usr/sbin/faillog ] || \
       [ -u /usr/sbin/lastlog ]
    then
      echo "${FUNCNAME}(): notice: you seem to be missing a security patch for SSA:2011-101-01"
      /usr/bin/chmod -c u-s	/usr/sbin/faillog
      /usr/bin/chmod -c u-s	/usr/sbin/lastlog
    fi

    # the process accounting log file:
    if [ -f /var/log/pacct ]
    then
      /usr/bin/chmod -c 600 /var/log/pacct
    fi

    # adjust the www permissions, so that regular users can't read
    # your database credentials from some php file etc. also so that
    # apache can't write there, in case of some web app vulns.
    if [ -d "${WWWROOT}" ]
    then
      # TODO: dokuwiki creates files which are apache:apache, should we ignore those?
      /usr/bin/chown -cR root:apache ${WWWROOT}
      #find ${WWWROOT} -type d -exec /usr/bin/chmod -c 750 '{}' \;
      #find ${WWWROOT} -type f -exec /usr/bin/chmod -c 640 '{}' \;

      # some dirs might need to be writable by apache, so we'll just do this:
      find ${WWWROOT} -exec /usr/bin/chmod -c o-rwx '{}' \;
    fi

    # man 5 limits:
    # "It should be owned by root and readable by root account only."
    if [ -f "/etc/limits" ]
    then
      /usr/bin/chown -c root:root	/etc/limits
      /usr/bin/chmod -c 600		/etc/limits
    fi

    # man 5 audisp-remote.conf:
    # "Note that the key file must be owned by root and mode 0400."
    if [ -f "/etc/audisp/audisp-remote.key" ]
    then
      /usr/bin/chown -c root:root	/etc/audisp/audisp-remote.key
      /usr/bin/chmod -c 400		/etc/audisp/audisp-remote.key
    fi

    # man 5 auditd.conf:
    # "Note that the key file must be owned by root and mode 0400."
    if [ -f "/etc/audit/audit.key" ]
    then
      /usr/bin/chown -c root:root	/etc/audit/audit.key
      /usr/bin/chmod -c 400		/etc/audit/audit.key
    fi

    # sudo: /etc/sudoers is mode 0640, should be 0440
    # visudo -c says: "/etc/sudoers: bad permissions, should be mode 0440"
    /usr/bin/chmod -c 0440 /etc/sudoers

    # wpa_supplicant conf might include pre-shared keys or private key passphrases.
    chmod -c 600 /etc/wpa_supplicant.conf

    # snmptrapd.conf might have SNMP credentials
    chmod -c 600 /etc/snmp/snmptrapd.conf

    # there can be SO many log files under /var/log, so i think this is the safest bet.
    # any idea if there's some log files that should be world-readable? for instance Xorg.n.log?
    #
    # NOTE: wtmp has special ownership/permissions which are handled by the etc package (.new)
    #       and logrotate
    # NOTE: ideally, all the permissions of the files should be handled by syslog/logrotate/etc...
    #
    #/usr/bin/find /var/log -type f -maxdepth 1 \! -name 'wtmp*' -exec /usr/bin/chmod -c 600 '{}' \;
    # we define mindepth here, so /var/log itself doesn't get chmodded. if there are some logs files
    # that need to be written by some other user (for instance tor), it doesn't work if /var/log
    # is with 700 permissions.
    /usr/bin/find /var/log -type d -maxdepth 1 -mindepth 1 -group root	-exec /usr/bin/chgrp -c adm	'{}' \;
    /usr/bin/find /var/log -type d -maxdepth 1 -mindepth 1 -group adm	-exec /usr/bin/chmod -c 750	'{}' \;
    /usr/bin/find /var/log -type d -maxdepth 1 -mindepth 1		-exec /usr/bin/chmod -c o-rwx	'{}' \;
    #/usr/bin/find /var/log -type d -maxdepth 1 -mindepth 1 -exec /usr/bin/chmod -c 700 '{}' \;

    #/usr/bin/find /var/log -type f -name 'wtmp*' -exec /usr/bin/chmod -c 660 '{}' \;
    #chmod -c 660 /var/log/wtmp

    # DEBIAN SPECIFIC
    chmod -c 600 /etc/network/interfaces

    # if you have nagios installed. also this is because of grsec's TPE:
    if [ -d /usr/libexec/nagios ]
    then
      chown -c root:nagios /usr/libexec/nagios
      chmod -c 750 /usr/libexec/nagios
    fi

    # make lastlog adm readable
    chown -c root:adm	/var/log/lastlog
    chmod -c 640	/var/log/lastlog
  } | tee -a "${logdir}/file_perms.txt"

  return 0
} # file_permissions()
################################################################################
function file_permissions2() {
  local FILE
  cat 0<<-EOF
	
	hardening file permissions
	--------------------------
EOF
  # new RH/Debian safe file permissions function
  {
    for FILE in ${!FILE_PERMS[*]}
    do
      if [ -f "${FILE}" ]
      then
	chmod -c ${FILE_PERMS[${FILE}]} ${FILE}
      fi
    done
  } | tee -a "${logdir}/file_perms.txt"
} # file_permissions2()
################################################################################
function user_home_directories_permissions() {
  # this has been split into it's own function, since it relates to both
  # "hardening categories", user accounts & file permissions.
  local DIR
  cat 0<<-EOF
	
	setting permissions of home directories
	---------------------------------------
EOF
  if [ -z "${UID_MIN}" -o -z "${UID_MAX}" ]
  then
    echo '[-] error: UID_MIN or UID_MAX not known' 1>&2
    return 1
  fi
  # 8.7 User Home Directories Should Be Mode 750 or More Restrictive (modified)
  for DIR in \
    $( awk -F: -v uid_min=${UID_MIN} -v uid_max=${UID_MAX} '($3 >= uid_min && $3 <= uid_max) { print $6 }' /etc/passwd ) \
    /root
  do
    if [ "x${DIR}" != "x/" ]
    then
      chmod -c 700 ${DIR} | tee -a "${logdir}/file_perms.txt"
    fi
  done

  return
} # user_home_directories_permissions()
################################################################################
function create_ftpusers() {
  local NAME
  local uid
  # CIS 7.3 Create ftpusers Files (modified)
  #
  # FTPUSERS(5):
  #   ftpusers - list of users that may not log in via the FTP daemon
  #
  # NOTE: there's a /etc/vsftpd.ftpusers file described in the CIS document, but
  #       i didn't find any reference to it in vsftpd's own documentation.
  #
  # NOTE: this file is created even if there's no FTP daemon installed.
  #       if proftpd package is installed afterwards, it leaves it's own
  #       ftpusers as .new.
  #
  # NOTE: proftpd's own ftpusers include accounts: ftp, root, uucp & news
  #
  # NOTE: this should be run periodically, since it's a blacklist and
  #       additional user accounts might be created after this.

  cat 0<<-EOF
	
	creating /etc/ftpusers
	----------------------
EOF
  # get the login names
  for NAME in ${NAMES[*]}
  do
    uid=$(id -u "${NAME}")
    # as the NAMES array is populated in the beginning of the script, some user
    # accounts might have been hardened away already at this point.
    if [ -z "${uid}" ]
    then
      continue
    fi
    if [ ${uid} -lt 500 ]
    then
      # add the name to ftpusers only if it's not already in there.
      # this should work whether the ftpusers file exists already or not.
      grep -q "^${NAME}$" /etc/ftpusers 2>/dev/null || {
	echo "  \`${NAME}'"
	echo "${NAME}" 1>> /etc/ftpusers
      }
    fi
  done
  return
} # create_ftpusers()
################################################################################
function set_failure_limits() {
  local i
  local j=1
  # from system-hardening-10.2.txt (modified)
  # the UID_MIN and UID_MAX values are from /etc/login.defs
  # locks user accounts after 5 failed logins

  cat 0<<-EOF
	
	setting failure limits
	----------------------
EOF
  if ! hash faillog 2>/dev/null
  then
    echo "[-] faillog binary not found" 1>&2
    return 1
  fi
  echo "[+] setting the maximum number of login failures for UIDs ${UID_MIN:-1000}-${UID_MAX:-60000} to ${FAILURE_LIMIT:-5}"

  # NOTE: from FAILLOG(8): "The maximum failure count should always be 0 for root to prevent a denial of services attack against the system."
  # TODO: for important user accounts, the limits should be -l $((60*10)) -m 1
  #       this makes the account to temporary lock for n seconds.

  # this if is because of some bug/feature in shadow suite. if the database file is of zero size, for some reason it doesn't work with one command:
  #   # ls -l /var/log/faillog 
  #   -rw-r--r-- 1 root root 0 Oct  5 00:03 /var/log/faillog
  #   # faillog -l 300 -m 1 -u root
  #   # faillog -u root
  #   Login       Failures Maximum Latest                   On
  #   
  #   root            0        1   01/01/70 02:00:00 +0200  
  #   # faillog -l 300 -m 1 -u root
  #   # faillog -u root
  #   Login       Failures Maximum Latest                   On
  #   
  #   root            0        1   01/01/70 02:00:00 +0200   [300s lock]
  #
  # the bug/feature exists somewhere inside the set_locktime_one() function of lastlog.c ... probably

  if [ -s /var/log/faillog ]
  then
    j=2
  fi
  for ((i=0; i<${j}; i++))
  do
    faillog -a -l $((60*15)) -m ${FAILURE_LIMIT:-5} -u ${UID_MIN:-1000}-${UID_MAX:-60000}
  done
  return ${?}
} # set_failure_limits()
################################################################################
function miscellaneous_settings() {
  # NOTES:
  #   - it is recommended to run file_permissions() after this function
  #     this function might create some files that don't have secure file permissions
  #
  # TODO:
  #   - tcp_diag module to rc.modules

  # CIS 7.4 Prevent X Server From Listening On Port 6000/tcp (kinda the same)
  #if [ -f "/usr/bin/startx" ]
  #then
  #  sed -i 's/^defaultserverargs=""$/defaultserverargs="-nolisten tcp"/' /usr/bin/startx
  #fi
  if [ -d /etc/X11/xinit ] && [ ! -f /etc/X11/xinit/xserverrc ]
  then
    # from http://docs.slackware.com/howtos:security:basic_security#x_-nolisten_tcp
    cat 0<<-EOF 1>/etc/X11/xinit/xserverrc
	#!/bin/sh

	exec /usr/bin/X -nolisten tcp
EOF
  fi

  # this is done so the CIS_Apache_v2_1.audit works with Nessus
  # "CIS Recommends removing the default httpd.conf and
  # creating an empty one in /usr/local/apache2/conf."
  #
  # http://www.nessus.org/plugins/index.php?view=single&id=21157
  #
  # NOTE: disabled for now
  #
  # TODO: we need to add a check if apache is even installed
  #mkdir -m 755 -v /usr/local/apache2 && {
  #  ln -sv /etc/httpd /usr/local/apache2/conf
  #  ln -sv /var/log/httpd /usr/local/apache2/logs
  #}

  # END OF CIS

  ##############################################################################
  # from system-hardening-10.2.txt:
  ##############################################################################

  # Account processing is turned on by /etc/rc.d/rc.M.  However, the log file
  # doesn't exist.
  if [ ! -f /var/log/pacct ]
  then
    touch /var/log/pacct
    {
      chgrp -c adm /var/log/pacct
      chmod -c 640 /var/log/pacct
    } | tee -a "${logdir}/file_perms.txt"
  fi

  # man 1 xfs
  if [ -f "/etc/X11/fs/config" ]
  then
    sed -i 's/^use-syslog = off$/use-syslog = on/' /etc/X11/fs/config
  fi

  if [ -f "/etc/X11/xdm/Xservers" ]
  then
    sed -i 's/^:0 local \/usr\/bin\/X :0\s*$/:0 local \/usr\/bin\/X -nolisten tcp/' /etc/X11/xdm/Xservers
  fi

  ##############################################################################
  # </system-hardening-10.2.txt>
  ##############################################################################

  # make installpkg store the MD5 checksums
  sed -i 's/^\(MD5SUM\)=0$/\1=1/' /sbin/installpkg

  # NOTE: according to slack14.0 CHANGES_AND_HINTS.TXT, blacklist.conf is a
  #       "stale" file.
  #grep -q "^blacklist ipv6$" /etc/modprobe.d/blacklist.conf 2>/dev/null
  #if [ ${?} -ne 0 ]
  #then
  #  echo "# Disable IPv6" 1>>/etc/modprobe.d/blacklist.conf
  #  echo "blacklist ipv6" 1>>/etc/modprobe.d/blacklist.conf
  #fi

  # disable killing of X with Ctrl+Alt+Backspace
  if [ -d /etc/X11/xorg.conf.d ]
  then
    cat 0<<-EOF 1>/etc/X11/xorg.conf.d/99-dontzap.conf
	Section "ServerFlags"
		Option "DontZap" "true"
	EndSection
EOF
#    cat 0<<-EOF 1>/etc/X11/xorg.conf.d/99-cve-2012-0064.conf
#	# see CVE-2012-0064:
#	#   http://seclists.org/oss-sec/2012/q1/191
#	#   http://article.gmane.org/gmane.comp.security.oss.general/6747
#	#   https://bugs.gentoo.org/show_bug.cgi?id=CVE-2012-0064
#	#   http://security-tracker.debian.org/tracker/CVE-2012-0064
#	#   http://packetstormsecurity.org/files/cve/CVE-2012-0064
#	#   http://www.x.org/archive/X11R6.8.1/doc/Xorg.1.html
#	#   http://gu1.aeroxteam.fr/2012/01/19/bypass-screensaver-locker-program-xorg-111-and-up/
#	#   http://who-t.blogspot.com/2012/01/xkb-breaking-grabs-cve-2012-0064.html
#	#   https://lwn.net/Articles/477062/
#	Section "ServerFlags"
#		Option "AllowDeactivateGrabs"	"false"
#		Option "AllowClosedownGrabs"	"false"
#	EndSection
#EOF
  fi

  [ -f /etc/X11/app-defaults/XScreenSaver ] && {
    true
    # TODO: newLoginCommand
  }

  # TODO: Xwrapper.config

  [ -f /etc/X11/xdm/Xresources ] && {
    #echo "xlogin*unsecureGreeting: This is an unsecure session" 1>>/etc/X11/xdm/Xresources
    #echo "xlogin*allowRootLogin: false" 1>>/etc/X11/xdm/Xresources
    true
  }

  enable_bootlog

  # make run-parts print "$SCRIPT failed." to stderr, so cron can mail this info to root.
  sed -i 's/\(echo "\$SCRIPT failed."\)$/\1 1>\&2/' /usr/bin/run-parts

  return 0
} # miscellaneous settings()
################################################################################
function enable_bootlog() {
  cat 0<<-EOF
	
	enabling bootlog
	----------------
EOF
  # https://www.linuxquestions.org/questions/slackware-14/how-to-activate-bootlogd-918962/
  if [ ! -f /var/log/boot ]
  then
    echo '[+] creating /var/log/boot'
    touch /var/log/boot
    {
      chown -c root:adm	/var/log/boot
      chmod -c 640	/var/log/boot
    } | tee -a "${logdir}/file_perms.txt"
  fi
} # enable_bootlog()
################################################################################
function remove_shells() {
  # see SHELLS(5)
  #
  # NOTES:
  #   - /bin/csh -> tcsh*
  #   - the entries in /etc/shells should be checked periodically, since the
  #     entries are added dynamically from doinst.sh scripts
  local SHELL_TO_REMOVE

  cat 0<<-EOF
	
	removing unnecessary shells
	---------------------------
EOF

  # tcsh csh ash ksh zsh	from Slackware
  # es rc esh dash screen	from Debian
  for SHELL_TO_REMOVE in \
    tcsh csh ash ksh zsh \
    es rc esh dash screen
  do
    sed -i '/^\/bin\/'"${SHELL_TO_REMOVE}"'$/d'		/etc/shells
    # for Debian
    sed -i '/^\/usr\/bin\/'"${SHELL_TO_REMOVE}"'$/d'	/etc/shells
  done

  # this is so that we can use this on other systems too...
  if [ -x /sbin/removepkg ]
  then
    for SHELL_TO_REMOVE in tcsh ash ksh93 zsh
    do
      /sbin/removepkg "${SHELL_TO_REMOVE}" 2>/dev/null
    done | tee -a "${logdir}/removed_packages.txt"
  fi

  # see "RESTRICTED SHELL" on BASH(1)
  if [ ! -h /bin/rbash ]
  then
    echo "[+] creating rbash link for restricted bash"
    pushd /bin
    ln -sv bash rbash && useradd -D -s /bin/rbash
    popd
  elif [ -h /bin/rbash ]
  then
    useradd -D -s /bin/rbash
  fi

  create_environment_for_restricted_shell

  # Debian
  # don't use dash as the default shell
  # there's some weird bug when using PAM's polyinstation
  if [ -x /usr/bin/debconf-set-selections -a \
       -x /usr/sbin/dpkg-reconfigure ]
  then
    echo 'dash    dash/sh boolean false' | debconf-set-selections -v
    dpkg-reconfigure -f noninteractive dash
  fi

  # add rbash to shells
  # NOTE: restricted shells shouldn't be listed in /etc/shells!!!
  # see man pages su & chsh, plus chsh.c for reasons why...
  #
  # also, see http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=424672
  #grep -q "^/bin/rbash$" /etc/shells || {
  #  echo "adding rbash to shells"
  #  echo "/bin/rbash" 1>>/etc/shells
  #}

  return 0
} # remove_shells()
################################################################################
function configure_apache() {
  # TODO: under construction!!!
  #   - apply the patch file
  #
  # NOTES:
  #   - /var/www ownership and permissions are hardened from file_permissions()

  local -i RET=0
  local    PATCH_FILE="${APACHE_PATCH_FILE}"
  local    module

  [ ! -f "/etc/httpd/httpd.conf" ] && {
    echo "${FUNCNAME}(): warning: apache configuration file \`/etc/httpd/httpd.conf' does not exist, maybe apache is not installed. skipping this part."
    return 0
  }

  # disable modules with sed. this is because x86 vs. x86_64 configs differ,
  # and there's no sense in having two separate patch files.
  for module in ${apache_disable_modules_list[*]}
  do
    grep -q "^LoadModule ${module}" /etc/httpd/httpd.conf
    if [ ${?} -ne 0 ]
    then
      continue
    fi
    if [ "${module:(-1):1}" = "_" ]
    then
      echo "disabling apache modules \`${module}'"
    else
      echo "disabling apache module \`${module}'"
    fi
    sed -i '/^LoadModule '"${module}"'/s/^/#/' /etc/httpd/httpd.conf
  done

  [ ! -f "${PATCH_FILE}" ] && {
    echo "${FUNCNAME}(): error: apache hardening patch (\`${PATCH_FILE}') does not exist!" 1>&2
    return 1
  }

  check_and_patch /etc/httpd "${APACHE_PATCH_FILE}"	3

  /usr/sbin/apachectl configtest || {
    echo "${FUNCNAME}(): error: something wen't wrong!" 1>&2
    RET=1
  }

  # TODO: apachectl restart
  return ${RET}
} # configure_apache()
################################################################################
# TODO: rename this function
function disable_unnecessary_services() {
  # NOTES:
  #   - this should probably be run only on fresh installations
  #   - this relates to CIS 3.4 "Disable Standard Boot Services"

  # TODO:
  #   - support for sysvinit scripts
  local RC
  local WHILELISTED
  local service

  echo "${FUNCNAME}(): disabling and shutting down unnecessary services"

  # go through all the rc scripts
  shopt -s nullglob
  for RC in /etc/rc.d/rc.*
  do
    # there might also be directories...
    if [ ! -f "${RC}" ]
    then
      echo "${FUNCNAME}(): DEBUG: \`${RC}' is not a file -> skipping" 1>&2
      continue
    # leftovers from patch
    elif [ "${RC:(-5):5}" = ".orig" ]
    then
      echo ".orig file -> skipping" 1>&2
      continue
    elif [ "${RC:(-1):1}" = "~" ]
    then
      echo "tilde file -> skipping" 1>&2
      continue
    fi
    #echo "${FUNCNAME}(): DEBUG: processing \`${RC}'"
    # go through the whitelist
    for WHITELISTED in ${SERVICES_WHITELIST[*]}
    do
      # service is whitelisted, continue with the next $RC
      if [ "${RC}" = "${WHITELISTED}" ]
      then
        echo "${FUNCNAME}(): skipping whitelisted service: \`${RC}'"
        continue 2
      fi
    done
    #echo "${RC} -> NOT WHITELISTED"

    # if it's executable, it's probably running -> shut it down
    [ -x "${RC}" ] && sh "${RC}" stop

    # and then disable it
    /usr/bin/chmod -c 600 "${RC}" | tee -a "${logdir}/file_perms.txt"
  done

  disable_unnecessary_systemd_services

  echo "${FUNCNAME}(): enabling recommended services"

  enable_sysstat

  # CIS 2.2 Configure TCP Wrappers and Firewall to Limit Access (applied)
  #
  # NOTE: the rc.firewall script should be created by the etc patch
  /usr/bin/chmod -c 700 /etc/rc.d/rc.firewall | tee -a "${logdir}/file_perms.txt"

  # inetd goes with the territory
  disable_inetd_services

  return 0
} # disable_unnecessary_services()
################################################################################
function disable_unnecessary_systemd_services() {
  local service

  cat 0<<-EOF
	
	disabling unnecessary systemd services
	--------------------------------------
EOF
  if [ ! -x /bin/systemctl ]
  then
    echo '[-] /bin/systemctl not found!' 1>&2
    return 1
  fi
  for service in atd avahi-daemon bind9 bluetooth cups exim4 hciuart ifup@wlan0 nfs-common vsftpd
  do
    if /bin/systemctl is-enabled "${service}" 1>/dev/null
    then
      /bin/systemctl stop	"${service}"
    fi
    /bin/systemctl disable	"${service}"
  done

  if [ -f /etc/xdg/autostart/zeitgeist-datahub.desktop ]
  then
    true
  fi
  # TODO: apt-get remove zeitgeist-datahub zeitgeist-core xul-ext-ubufox
} # disable_unnecessary_systemd_services()
################################################################################
function gnome_settings() {
  # Settings -> Privacy -> Usage & History -> Recently Used
  gsettings set org.gnome.desktop.privacy remember-recent-files false
  gsettings set org.gnome.desktop.privacy recent-files-max-age  1
  # TODO: Clear Recent History
  gsettings set org.gnome.system.location enabled false
} # gnome_settings()
################################################################################
function create_limited_ca_list() {
  local -i ret
  cat 0<<-EOF
	
	Hardening trusted CA certificates
	---------------------------------
EOF
  if [ ! -x /usr/sbin/update-ca-certificates ]
  then
    echo "[-] ERROR: update-ca-certificates not found!" 1>&2
    return 1
  elif [ ! -f /etc/ca-certificates.conf ]
  then
    echo "[-] ERROR: /etc/ca-certificates.conf not found!" 1>&2
    return 1
  fi
  if [ ! -f /etc/ca-certificates.conf.original ]
  then
    cp -v /etc/ca-certificates.conf /etc/ca-certificates.conf.original
  fi
  # Debian's ssl-cert package runs the make-ssl-cert and creates the snakeoil cert
  if [ -f /etc/ssl/certs/ssl-cert-snakeoil.pem ]
  then
    rm -v /etc/ssl/certs/ssl-cert-snakeoil.pem
  fi
  make -f ${CWD}/Makefile /etc/ssl/certs/ca-certificates.crt | tee "${logdir}/ca_certificates.txt"
  ret=${PIPESTATUS[0]}

  return ${ret}
} # create_limited_ca_list()
################################################################################
function sysctl_harden() {
  cat 0<<-EOF
	
	applying sysctl hardening
	-------------------------
EOF
  if [ -f "${CWD}/newconfs/sysctl.conf.new" ]
  then
    if [ -d /etc/sysctl.d ]
    then
      # for debian
      cat "${CWD}/newconfs/sysctl.conf.new" 1>/etc/sysctl.d/harden.conf
      echo "[+] written to /etc/sysctl.d/harden.conf"
    else
      # slackware
      # TODO: add some check if it's already there.
      cat "${CWD}/newconfs/sysctl.conf.new" 1>>/etc/sysctl.conf
      echo "[+] written to /etc/sysctl.conf"
    fi
  else
    echo "[-] WARNING: sysctl.conf.new not found!" 1>&2
  fi
} # sysctl_harden()
################################################################################
function quick_harden() {
  # this function is designed to do only some basic hardening. so that it can
  # be used in other systems/version that are not directly supported by this
  # script.
  #
  # TODO: under construction
  local func

  # configure TCP wrappers
  # TODO: make into separate function
  if ! grep -q "^ALL" /etc/hosts.deny
  then
    echo "ALL: ALL EXCEPT localhost" 1>>/etc/hosts.deny
  fi

  for func in \
    sysctl_harden                        \
    set_failure_limits                   \
    create_ftpusers                      \
    remove_shells                        \
    harden_fstab                         \
    enable_sysstat                       \
    create_limited_ca_list               \
    lock_system_accounts                 \
    configure_apt                        \
    configure_securetty                  \
    configure_pam                        \
    configure_core_dumps                 \
    disable_unnecessary_systemd_services \
    configure_password_policies          \
    restrict_cron                        \
    configure_sshd                       \
    configure_basic_auditing             \
    enable_bootlog                       \
    user_home_directories_permissions    \
    enable_apparmor                      \
    aa_enforce                           \
    disable_gdm3_user_list
  do
    ${func}
  done
  apply_newconfs modprobe.d profile.d
  # TODO: chmod tmout.sh

  return
} # quick_harden()
################################################################################
function apply_newconfs() {
  local    newconf
  local    basename
  local    subdir
  local -a sha256sums

  cat 0<<-EOF
	
	applying .new confs
	-------------------
EOF

  pushd /etc 1>/dev/null || {
    echo "[-] error!" 1>&2
    return 1
  }
  shopt -s nullglob
  for subdir in ${*}
  do
    if [ ! -d "${CWD}/newconfs/${subdir}" ]
    then
      echo "[-] error: ${subdir} directory does not exist!" 1>&2
      continue
    fi
    for newconf in ${CWD}/newconfs/${subdir}/*.new
    do
      basename=$( basename "${newconf}" )
      # check if the file exists
      if [ ! -f "${subdir}/${basename%.new}" ]
      then
	# if not, move the .new into place
        echo "[+] creating new file \`${subdir}/${basename%.new}'"
	cat "${newconf}" 1>"${subdir}/${basename%.new}"
      elif
	sha256sums=( $( sha256sum "${subdir}/${basename%.new}" "${newconf}" | awk '{print$1}' ) )
	[ "${sha256sums[0]}" != "${sha256sums[1]}" ]
      then
	echo "[+] file \`${subdir}/${basename%.new}' exists. creating \`${subdir}/${basename}'."
	# leave the .new file for the admin to consider
	cat "${newconf}" 1>"${subdir}/${basename}"
      else
	echo "[+] file \`${subdir}/${basename%.new}' exists"
      fi
    done
  done
  popd 1>/dev/null
} # apply_newconfs()
################################################################################
function toggle_usb_authorized_default() {
  local host
  local state

  cat 0<<-EOF
	
	USB authorized_default
	----------------------
EOF

  for host in /sys/bus/usb/devices/usb*
  do
    read state 0<"${host}/authorized_default"
    ((state^=1))
    if (( ${state} ))
    then
      echo "[+] setting ${host} to authorized_default"
    else
      echo "[+] setting ${host} to !authorized"
    fi
    echo "${state}" > ${host}/authorized_default
  done

  return 0
} # toggle_usb_authorized_default()
################################################################################
function configure_basic_auditing() {
  local -a stig_rules=()
  local    concat="/bin/cat"
  local    rule_file

  cat 0<<-EOF
	
	configuring basic auditing
	--------------------------
EOF

  if [ ! -x /sbin/auditctl ]
  then
    echo "[-] error: auditctl not found!" 1>&2
    return 1
  fi
  if [ ! -d /etc/audit/rules.d ]
  then
    echo "[-] error: rules directory \`/etc/audit/rules.d' does not exist!" 1>&2
    return 1
  fi

  # Debian
  if [ -f /usr/share/doc/auditd/examples/stig.rules.gz ]
  then
    stig_rules[0]="/usr/share/doc/auditd/examples/stig.rules.gz"
    concat="/bin/zcat"
  # Kali
  elif [ -f /usr/share/doc/auditd/examples/rules/30-stig.rules.gz ]
  then
    stig_rules[0]="/usr/share/doc/auditd/examples/rules/30-stig.rules.gz"
    concat="/bin/zcat"
  # Slackware
  elif [ -f /etc/slackware-version ]
  then
    stig_rules=( /usr/doc/audit-*/contrib/stig.rules )
  # CentOS
  elif [ -f /etc/centos-release ]
  then
    stig_rules=( /usr/share/doc/audit-*/stig.rules )
  fi

  if [ ${#stig_rules[*]} -ne 1 ]
  then
    echo "[-] error: stig.rules not found!" 1>&2
    return 1
  elif [ ! -f ${stig_rules[0]} ]
  then
    echo "[-] error: stig.rules not found!" 1>&2
    return 1
  fi

  # common for all distros
  #   - Enable auditing of lastlog
  #   - Enable session files logging ([ubw]tmp)
  #   - Add faillog auditing above lastlog
  #   - Enable kernel module logging
  #   - Enable auditing of tallylog
  #   - remove delete stuff (too excessive)
  ${concat} "${stig_rules[0]}" | sed \
    -e '/^#-w \/var\/log\/lastlog -p wa -k logins$/s/^#//' \
    -e '/^#-w \/var\/\(run\|log\)\/[ubw]tmp -p wa -k session$/s/^#//' \
    -e '/^-w \/var\/log\/lastlog -p wa -k logins$/i-w /var/log/faillog -p wa -k logins' \
    -e '/^#.*\(-k \|-F key=\)module.*$/s/^#//' \
    -e '/^#-w \/var\/log\/tallylog -p wa -k logins$/s/^#//' \
    -e '/^[^#].*-k delete/s/^/#/' \
    1>/etc/audit/rules.d/stig.rules
  # distro specific
  if [ "${DISTRO}" = "slackware" ]
  then
    # fix the audit.rules for Slackware:
    #   - Slackware does not have old passwords (opasswd)
    #   - Slackware does not have /etc/sysconfig/network
    #   - Slackware does not have pam_tally
    sed -i \
      -e '/^-w \/etc\/security\/opasswd -p wa -k identity$/s/^/#/' \
      -e '/^-w \/etc\/sysconfig\/network -p wa -k system-locale$/s/^/#/' \
      -e '/^-w \/var\/log\/tallylog -p wa -k logins$/s/^/#/' \
      /etc/audit/rules.d/stig.rules
  elif [ "${DISTRO}" = "debian" -o "${DISTRO}" = "raspbian" ]
  then
    # /etc/sysconfig/network -> /etc/network
    sed -i \
      -e 's:^-w /etc/sysconfig/network -p wa -k system-locale$:-w /etc/network -p wa -k system-locale:' \
      /etc/audit/rules.d/stig.rules
  fi

  # fix the UID_MIN
  if [ -n "${UID_MIN}" ]
  then
    sed -i "s/auid>=500/auid>=${UID_MIN}/" /etc/audit/rules.d/stig.rules
  fi

  # set the correct architecture
  # TODO: armv7l etc.?
  if [[ ${ARCH} =~ ^i.86$ ]]
  then
    # disable x86_64 rules
    sed -i '/^-.*arch=b64/s/^/#/' /etc/audit/rules.d/stig.rules
  #elif [ "${ARCH}" = "x86_64" ]
  #then
  #  # disable x86 rules
  #  sed -i '/^-.*arch=b32/s/^/#/' /etc/audit/rules.d/stig.rules
  fi

  # drop in few custom rules
  for rule_file in ld.so tmpexec
  do
    /bin/cat "${CWD}/newconfs/rules.d/${rule_file}.rules.new" 1>"/etc/audit/rules.d/${rule_file}.rules"
  done

  # create /etc/audit/audit.rules with augenrules
  /sbin/augenrules
  if [ -f /etc/audit/audit.rules.prev ]
  then
    echo "NOTICE: previous audit.rules existed and was copied to audit.rules.prev by augenrules:"
    ls -l /etc/audit/audit.rules.prev
  fi
  # read rules from file
  /sbin/auditctl -R /etc/audit/audit.rules

  # enable the service
  if [ -f /etc/rc.d/rc.auditd ]
  then
    chmod -c 700 /etc/rc.d/rc.auditd | tee -a "${logdir}/file_perms.txt"
  elif [ -x /bin/systemctl ]
  then
    /bin/systemctl enable auditd
  fi

  echo '[+] configuring auditd.conf'
  for setting in ${!AUDITD_CONFIG[*]}
  do
    # ^key = value$
    sed_with_diff "s/^\(# \?\)\?\(${setting}\)\(\s\+=\s\+\)\S\+$/\2\3${AUDITD_CONFIG[${setting}]}/" /etc/audit/auditd.conf
  done

  # enable it in grub/lilo
  if [ -f /etc/default/grub ] && ! grep -q '^GRUB_CMDLINE_LINUX=".*audit=1' /etc/default/grub
  then
    # example: https://wiki.debian.org/AppArmor/HowToUse#Enable_AppArmor
    sed_with_diff 's/^\(GRUB_CMDLINE_LINUX=".*\)"$/\1 audit=1"/' /etc/default/grub
    echo "NOTICE: /etc/default/grub updated. you need to run \`update-grub' or \`grub2-install' to update the boot loader."
  elif [ -f /etc/lilo.conf ] && ! grep -q '^append=".*audit=1' /etc/lilo.conf
  then
    sed_with_diff 's/^\(append=".*\)"$/\1 audit=1"/' /etc/lilo.conf
    echo "NOTICE: /etc/lilo.conf updated. you need to run \`lilo' to update the boot loader."
  # raspbian
  elif [ -f /boot/cmdline.txt ] && ! grep -q 'audit=1' /boot/cmdline.txt
  then
    sed_with_diff 's/$/ audit=1/' /boot/cmdline.txt
  fi
} # configure_basic_auditing()
################################################################################
function patch_sendmail() {
  # $1 = [reverse]

  local REV=""

  if [ ${#} -eq 1 ]
  then
    REV="${1}"
  fi

  if [ ! -d "/etc/mail" ]
  then
    echo "${FUNCNAME}(): error: sendmail config dir not found!" 1>&2
    return 1
  elif [ ! -d "${SENDMAIL_CF_DIR}" ]
  then
    echo "${FUNCNAME}(): error: no such directory \`${SENDMAIL_CF_DIR}'! you might not have the sendmail-cf package installed." 1>&2
    return 1
  elif [ ! -f "${SENDMAIL_CF_DIR}/${SENDMAIL_CONF_PREFIX}.mc" ]
  then
    echo "${FUNCNAME}(): error: no such file \`${SENDMAIL_CF_DIR}/${SENDMAIL_CONF_PREFIX}.mc'! you might not have the sendmail-cf package installed." 1>&2
    return 1
  fi

  check_and_patch /usr/share/sendmail "${SENDMAIL_PATCH_FILE}" 1 "${REV}" || {
    echo "${FUNCNAME}(): error!" 1>&2
    return 1
  }
  pushd ${SENDMAIL_CF_DIR} || {
    echo "${FUNCNAME}(): error!" 1>&2
    return 1
  }
  # build the config
  sh ./Build "./${SENDMAIL_CONF_PREFIX}.mc" || {
    echo "${FUNCNAME}(): error: error while building the sendmail config!" 1>&2
    popd
    return 1
  }
  if [ ! -f "/etc/mail/sendmail.cf.bak" ]
  then
    cp -v /etc/mail/sendmail.cf /etc/mail/sendmail.cf.bak
  fi
  cp -v "./${SENDMAIL_CONF_PREFIX}.cf" /etc/mail/sendmail.cf
  popd

  # don't reveal the sendmail version
  # no patch file for single line! =)
  sed -i 's/^smtp\tThis is sendmail version \$v$/smtp\tThis is sendmail/' /etc/mail/helpfile

  # if sendmail is running, restart it
  if [ -f "/var/run/sendmail.pid" ] && [ -x "/etc/rc.d/rc.sendmail" ]
  then
    /etc/rc.d/rc.sendmail restart
  fi

  return 0
} # patch_sendmail()
################################################################################
function check_integrity() {
  local    manifest="${MANIFEST_DIR}/MANIFEST.bz2"
  local -i I=0
  local    FULL_PERM
  local    OWNER_GROUP
  local    SIZE
  local    PATH_NAME
  local -a STAT=()
  local    local_FULL_PERM
  local    local_OWNER_GROUP
  local    local_size

  make -f ${CWD}/Makefile slackware="${SLACKWARE}" slackware_version="${SLACKWARE_VERSION}" "${manifest}" || return 1

  pushd /

  # partly copied from http://www.slackware.com/%7Ealien/tools/restore_fileperms_from_manifest.sh
  while read line
  do
    if [[ ${line} =~ ^.(.{9})\ ([a-z]+/[a-z]+)\ +([0-9]+)\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}\ (.+)$ ]]
    then
      FULL_PERM="${BASH_REMATCH[1]}"
      OWNER_GROUP="${BASH_REMATCH[2]//\//:}"
      SIZE="${BASH_REMATCH[3]}"
      PATH_NAME="${BASH_REMATCH[4]}"
    fi

    if [ ! -e "${PATH_NAME}" ]
    then
      continue
    # if it's a link -> skip
    elif [ -h "${PATH_NAME}" ]
    then
      continue
    fi

    STAT=( $( stat -c"%A %U:%G %s" "${PATH_NAME}" ) )
    local_FULL_PERM="${STAT[0]:1:9}"
    local_OWNER_GROUP="${STAT[1]}"
    local_size="${STAT[2]}"

    if [ -z "${local_OWNER_GROUP}" -o -z "${local_FULL_PERM}" ]
    then
      continue
    fi

    if [ \
      "${FULL_PERM}"	!= "${local_FULL_PERM}" -o \
      "${OWNER_GROUP}"	!= "${local_OWNER_GROUP}" ]
    then
      echo "Path: ${PATH_NAME}"
      if [ "${FULL_PERM}" != "${local_FULL_PERM}" ]
      then
        printf " %-9s: %-33s, %s\n" "Perm" "${FULL_PERM}" "${local_FULL_PERM}"
      fi
      if [ "${OWNER_GROUP}" != "${local_OWNER_GROUP}" ]
      then
        printf " %-9s: %-33s, %s\n" "Owner" "${OWNER_GROUP}" "${local_OWNER_GROUP}"
      fi
      # the file sizes change during updates, so this is commented out for now...
      #if [ ${local_size} -ne 0 -a ${SIZE} -ne ${local_size} ]
      #then
      #  printf " %-9s: %-33s, %s\n" "Size" ${SIZE} ${local_size}
      #fi
      echo -n $'\n'
    fi
    ((I++))
  done 0< <(bzgrep -E "^[d-]" "${manifest}" | sort | uniq)
  echo "${I} paths checked"

  popd
} # check_integrity()
################################################################################
function usage() {
  cat 0<<-EOF
	harden.sh -- system hardening script for slackware linux

	usage: ${0} options

	options:

	  -a		apache
	  -A		all
	  		  - hardens user accounts
	  		  - removes unnecessary packages
	  		  - removes unnecessary shells
	  		  - imports PGP keys
	  		  - applies the etc hardening patch
	  		  - applies the sudoers hardening patch
	  		  - applies the SSH hardening patch
	  		  - disables unnecessary services
	  		  - miscellaneous_settings()
	  		  - hardens file permissions
	  		  - creates hardened fstab.new
	  -b		toggle USB authorized_default
	  -c		create limited CA conf
	  -d		default hardening (misc_settings() & file_permissions())

	  -f function	run a function. available functions:
	  		aa_enforce
	  		configure_apt
	  		configure_modprobe.d
	  		configure_pam
	  		configure_securetty
	  		configure_umask
	  		configure_shells
	  		core_dumps
	  		create_banners
	  		disable_ipv6
	  		disable_unnecessary_systemd_services
	  		enable_apparmor
	  		enable_bootlog
	  		enable_sysstat
	  		file_permissions
	  		file_permissions2
	  		lock_system_accounts
	  		password_policies
	  		restrict_cron
	  		sshd_config
	  		sysctl_harden
	  		homedir_perms
	  		disable_gdm3_user_list
	  -F		create/update /etc/ftpusers
	  -g		import Slackware, SBo & other PGP keys to trustedkeys.gpg keyring
	        	(you might also want to run this as a regular user)
	  -h		this help
	  -i		disable inetd services
	  -I		check Slackware installation's integrity from MANIFEST (owner & permission)
	  -l		set failure limits (faillog) (default value: ${FAILURE_LIMIT:-10})
	  -L user	lock account 'user'
	  -m		miscellaneous (TODO: remove this? default handles all this)
	  -M		fstab hardening (nodev, nosuid & noexec stuff)

	  patching:

	    -p patch	apply   hardening patch for [patch]
	    -P patch	reverse hardening patch for [patch]

	    available patches:
	      ssh
	      etc
	      apache
	      sendmail
	      php
	      sudoers
	      wipe **HIGHLY EXPERIMENTAL AND DANGEROUS**

	  -q	"quick harden" - just some generic stuff that should work on any system
	          - creates a deny all TCP wrappers rule
	          - creates sysctl.conf
	          - configures /etc/suauth to disallow the use of su
	          - sets failure limits
	          - creates ftpusers
	          - removes unnecessary shells
	          - creates hardened fstab.new
	          - creates limited CA list
	          - lock system accounts
	  -r	remove unnecessary shells
	  -s	disable unnecessary services (also enables few recommended ones)
	  -S	configure basic auditing using the stig.rules
	  -u	harden user accounts
	  -U	create additional user accounts (SBo related)

	Make targets:

	  /etc/ssh/moduli.new
	  /etc/ssh/ssh_host_{rsa,ecdsa,ed25519}_key
	  /etc/ssl/certs/ca-certificates.crt
	  /etc/securetty
	  /etc/fstab.new
	  manifest
EOF
  # print functions
  #declare -f 2>/dev/null | sed -n '/^.* () $/s/^/  /p'
  exit 0
} # usage()
################################################################################
function configure_securetty() {
  # https://www.debian.org/doc/manuals/securing-debian-howto/ch4.en.html#s-restrict-console-login
  local i
  cat 0<<-EOF
	
	creating /etc/securetty
	-----------------------
EOF
  {
    echo "console"
    for i in {1..6}
    do
      echo "tty${i}"
    done
  } 1>/etc/securetty
  {
    chown -c root:root	/etc/securetty
    chmod -c 400	/etc/securetty
  } | tee -a "${logdir}/file_perms.txt"
} # configure_securetty()
################################################################################
function configure_password_policies() {
  local policy

  cat 0<<-EOF
	
	configuring password policies
	-----------------------------
EOF

  if [ ! -f /etc/login.defs ]
  then
    echo "[-] error: /etc/login.defs not found!" 1>&2
    return 1
  fi

  for policy in ${!PASSWORD_POLICIES[*]}
  do
    printf "[+] %-20s -> %s\n" ${policy} ${PASSWORD_POLICIES[${policy}]}
    sed_with_diff "s/^\(# \?\)\?\(${policy}\)\(\s\+\)\S\+$/\2\3${PASSWORD_POLICIES[${policy}]}/" /etc/login.defs
  done

  #if [ -f /etc/libuser.conf ]
  #then
  #  # TODO: /etc/libuser.conf "crypt_style = sha512"
  #  true
  #fi

  # TODO: /etc/pam.d/common-password

  # red hat
  if [ -x /sbin/authconfig ]
  then
    # TODO: other settings
    /sbin/authconfig --passalgo=sha512 --update
  fi

  useradd -D -f ${password_inactive}

  configure_password_policy_for_existing_users

  read_password_policy
} # configure_password_policies()
################################################################################
function configure_sshd() {
  local setting
  cat 0<<-EOF
	
	configuring sshd
	----------------
EOF
  if [ ! -f /etc/ssh/sshd_config ]
  then
    echo "[-] error: /etc/ssh/sshd_config not found!" 1>&2
    return 1
  fi
  for setting in ${!SSHD_CONFIG[*]}
  do
    sed -i "s/^\(# \?\)\?\(${setting}\)\(\s\+\)\S\+$/\2\3${SSHD_CONFIG[${setting}]}/" /etc/ssh/sshd_config
    if ! grep -q "^${setting}\s\+${SSHD_CONFIG[${setting}]}$" /etc/ssh/sshd_config
    then
      echo "[-] failed to set ${setting}"
    fi
  done
  chmod -c ${FILE_PERMS["/etc/ssh/sshd_config"]} /etc/ssh/sshd_config | tee -a "${logdir}/file_perms.txt"
} # configure_sshd()
################################################################################
function disable_ipv6() {
  cat 0<<-EOF
	
	disabling IPv6
	--------------
EOF
  if [ -f /etc/default/grub ] && ! grep -q '^GRUB_CMDLINE_LINUX=".*ipv6.disable=1' /etc/default/grub
  then
    echo '[+] configuring /etc/default/grub'
    sed -i 's/^\(GRUB_CMDLINE_LINUX=".*\)"$/\1 ipv6.disable=1"/' /etc/default/grub
  # raspbian
  elif [ -f /boot/cmdline.txt ] && ! grep -q 'ipv6\.disable=1' /boot/cmdline.txt
  then
    echo '[+] configuring /boot/cmdline.txt'
    sed -i 's/$/ ipv6.disable=1/' /boot/cmdline.txt
  fi
} # disable_ipv6()
################################################################################
function configure_iptables_persistent() {
  # TODO
  true
} # configure_iptables_persistent()
################################################################################
function enable_selinux() {
  # TODO
  true
} # enable_selinux()
################################################################################
function configure_apt() {
  local suite
  cat 0<<-EOF
	
	disabling suggested packages in APT
	-----------------------------------
EOF
  if [ -d /etc/apt/apt.conf.d ]
  then
    echo 'APT::Install-Suggests "false";' 1>/etc/apt/apt.conf.d/99suggested
  else
    echo '[-] /etc/apt/apt.conf.d not found. maybe this is not Debian based host.'
  fi

  # configure suite for better results
  if [ -x /usr/bin/lsb_release -a -f /etc/default/debsecan ]
  then
    suite=$( lsb_release -c -s )
    if [ -n "${suite}" ]
    then
      echo '[+] configuring suite to /etc/default/debsecan'
      sed -i "s/^SUITE=.*\$/SUITE=${suite}/" /etc/default/debsecan
    fi
  fi
} # configure_apt()
################################################################################
function disable_gdm3_user_list() {
  local setting
  local value
  cat 0<<-EOF
	
	configuring display manager(s)
	------------------------------
EOF

  if [ -f /etc/gdm3/greeter.dconf-defaults ]
  then
    echo '[+] disabling user list in /etc/gdm3/greeter.dconf-defaults'
    sed_with_diff '/disable-user-list=true$/s/^#\s*//' /etc/gdm3/greeter.dconf-defaults
    # TODO: go through the rest of /etc/gdm3/greeter.dconf-defaults
  elif [ -f /etc/lightdm/lightdm.conf ]
  then
    for setting in ${!LIGHTDM_CONFIG[*]}
    do
      value="${LIGHTDM_CONFIG[${setting}]}"
      echo "[+] setting ${setting} to ${value} in /etc/lightdm/lightdm.conf"
      # ^#\?key=value$
      sed_with_diff "s/^#\?\(${setting}\)=.*$/\1=${value}/" /etc/lightdm/lightdm.conf
    done
  else
    echo '[-] display manager greeter config not found'
  fi
  # https://wiki.ubuntu.com/LightDM#Disabling_Guest_Login
  if [ -d /etc/lightdm/lightdm.conf.d ]
  then
    echo '[+] disallowing guest sessions in LightDM'
    echo -e '[Seat:*]\nallow-guest=false' 1>/etc/lightdm/lightdm.conf.d/50-disallow-guest.conf
  fi
  # TODO: greeter-allow-guest in /etc/lightdm/lightdm.conf (in Pi)
} # disable_gdm3_user_list()
################################################################################
function configure_shells() {
  configure_umask
  remove_shells
  make -f ${CWD}/Makefile /etc/profile.d/tmout.sh
  # TODO: rbash
} # configure_shells()
################################################################################
function configure_umask() {
  cat 0<<-EOF
	
	configuring umask
	-----------------
EOF
  # TODO: utilize configure_password_policies()
  if [ -f /etc/login.defs ]
  then
    echo "[+] configuring /etc/login.defs"
    local policy="UMASK"
    sed_with_diff "s/^\(# \?\)\?\(${policy}\)\(\s\+\)\S\+$/\2\3${PASSWORD_POLICIES[${policy}]}/" /etc/login.defs
  else
    echo "[-] /etc/login.defs not found" 1>&2
  fi
  if [ -f /etc/bash.bashrc ]
  then
    if ! grep -q '^umask 077$' /etc/bash.bashrc
    then
      echo '[+] configuring umask to /etc/bash.bashrc'
      sed_with_diff '$a umask 077' /etc/bash.bashrc
    fi
  fi
  if [ -f /etc/init.d/functions ]
  then
    echo '[+] configuring umask to /etc/init.d/functions'
    sed_with_diff 's/^umask [0-9]\+$/umask 077/' /etc/init.d/functions
  fi
  make -f ${CWD}/Makefile /etc/profile.d/umask.sh
  configure_pam_umask
} # configure_umask()
################################################################################

if [ "${USER}" != "root" ]
then
  echo -e "[-] warning: you should probably be root to run this script\n" 1>&2
fi
if [ ${#NAMES[*]} -eq 0 ]
then
  echo '[-] warning: NAMES array not populated' 1>&2
fi

read_password_policy

while getopts "aAbcdf:FghHiIlL:mMp:P:qrsSuU" OPTION
do
  case "${OPTION}" in
    "a") configure_apache		;;
    "A")
      # this is intended to be a all-in-one parameter
      # that you can use on fresh installations

      # NOTES on ordering:
      #   - disabled_unnecessary_services AFTER patch_etc (rc.firewall for instance)

      #configure_apache
      user_accounts
      remove_packages
      remove_shells
      create_limited_ca_list
      import_pgp_keys
      check_and_patch /etc	"${ETC_PATCH_FILE}"	1 && ETC_CHANGED=1
      apply_newconfs . cron.d logrotate.d rc.d modprobe.d
      check_and_patch /etc	"${SUDOERS_PATCH_FILE}"	1
      check_and_patch /etc	"${SSH_PATCH_FILE}"	1

      # this should be run after patching etc,
      # there might be new rc scripts.
      disable_unnecessary_services

      miscellaneous_settings

      # these should be the last things to run
      file_permissions
      restrict_cron

      harden_fstab
      configure_basic_auditing
      configure_securetty

      # TODO: after restarting syslog,
      # there might be new log files with wrong permissions.
      (( ${ETC_CHANGED} )) && restart_services
    ;;
    "b") toggle_usb_authorized_default	;;
    "c") create_limited_ca_list		;;
    "d")
      # default
      miscellaneous_settings
      file_permissions
    ;;
    "f")
      case "${OPTARG}" in
	"aa_enforce")		aa_enforce			;;
	"configure_apt")	configure_apt			;;
	"configure_modprobe.d")	apply_newconfs modprobe.d	;;
	"configure_pam")	configure_pam			;;
	"configure_securetty")	configure_securetty		;;
	"create_banners")	create_banners			;;
	"core_dumps")		configure_core_dumps		;;
	"disable_ipv6")		disable_ipv6			;;
	"disable_unnecessary_systemd_services") disable_unnecessary_systemd_services ;;
	"enable_apparmor")	enable_apparmor			;;
	"enable_bootlog")	enable_bootlog			;;
	"enable_sysstat")	enable_sysstat			;;
	"file_permissions")	file_permissions		;;
	"file_permissions2")	file_permissions2		;;
	"lock_system_accounts")	lock_system_accounts		;;
	"password_policies")	configure_password_policies	;;
	"restrict_cron")	restrict_cron			;;
	"sshd_config")		configure_sshd			;;
	"sysctl_harden")	sysctl_harden			;;
	"homedir_perms")	user_home_directories_permissions ;;
	"disable_gdm3_user_list") disable_gdm3_user_list        ;;
	"configure_umask")	configure_umask			;;
	"configure_shells")	configure_shells		;;
	*)
	  echo "[-] unknown function" 1>&2
	  exit 1
	;;
      esac
    ;;
    "F") create_ftpusers		;;
    "g") import_pgp_keys		;;
    "h")
      usage
      exit 0
    ;;
    "i") disable_inetd_services		;;
    "I") check_integrity		;;
    "l") set_failure_limits		;;
    "L") lock_account "${OPTARG}"	;;
    "m")
      # TODO: remove?
      miscellaneous_settings
    ;;
    "M") harden_fstab			;;
    "p")
      case "${OPTARG}" in
	"ssh")
	  # CIS 1.3 Configure SSH
	  check_and_patch /etc "${SSH_PATCH_FILE}" 1 && \
            [ -f "/var/run/sshd.pid" ] && [ -x "/etc/rc.d/rc.sshd" ] && \
	      /etc/rc.d/rc.sshd restart
	;;
	"etc")		check_and_patch /etc "${ETC_PATCH_FILE}" 1 && ETC_CHANGED=1	;;
        "apache")	check_and_patch /etc/httpd "${APACHE_PATCH_FILE}" 3		;;
	"sendmail")	patch_sendmail							;;
	"php")		check_and_patch /etc/httpd php_harden.patch 1			;;
        "sudoers")	check_and_patch /etc "${SUDOERS_PATCH_FILE}" 1			;;
	"wipe")
	  check_and_patch /etc wipe.patch 1
	  {
	    chmod -c 700 /etc/rc.d/rc.{2,5}
	    chmod -c 700 /etc/rc.d/rc2.d/KluksHeaderRestore.sh
	    chmod -c 700 /etc/rc.d/rc.sysvinit
	  } | tee -a "${logdir}/file_perms.txt"
	  init q
	;;
	*) echo "error: unknown patch \`${OPTARG}'!" 1>&2 ;;
      esac
    ;;
    "P")
      # reverse a patch
      case "${OPTARG}" in
	"ssh")
	  check_and_patch /etc "${SSH_PATCH_FILE}" 1 reverse && \
	    [ -f "/var/run/sshd.pid" ] && [ -x "/etc/rc.d/rc.sshd" ] && \
	      /etc/rc.d/rc.sshd restart
	;;
	"etc")		check_and_patch /etc "${ETC_PATCH_FILE}" 1 reverse && ETC_CHANGED=1	;;
        "apache")	check_and_patch /etc/httpd "${APACHE_PATCH_FILE}" 3 reverse		;;
        "sendmail")	patch_sendmail reverse							;;
	"php")		check_and_patch /etc/httpd php_harden.patch 1 reverse			;;
        "sudoers")	check_and_patch /etc	"${SUDOERS_PATCH_FILE}"	1 reverse		;;
	"wipe")
	  check_and_patch /etc wipe.patch 1 reverse
          /sbin/init q
	;;
	*)		echo "error: unknown patch \`${OPTARG}'!" 1>&2				;;
      esac
    ;;
    "q") quick_harden			;;
    "r") remove_shells			;;
    "s") disable_unnecessary_services	;;
    "S") configure_basic_auditing	;;
    "u") user_accounts			;;
    "U") create_additional_user_accounts ;;
  esac
done

shopt -s nullglob
logfiles=( ${logdir}/* )
echo -n $'\n'
if [ ${#logfiles[*]} -eq 0 ]
then
  echo "no log files created. removing dir."
  rmdir -v "${logdir}"
else
  echo "logs available at: ${logdir}"
fi

exit 0
