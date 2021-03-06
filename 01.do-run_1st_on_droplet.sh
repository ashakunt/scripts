#!/bin/bash
#FIXME:
# 1. add error handling for every command
# 2. ask user if they want to continue after every error
# 3. never reboot if there were errors

show_help() {
    cat << HELP
Usage: $(basename $0) -u <username> -p <new ssh port>

HELP
}

what_it_does() {
    cat << NOTICE
This script is intended to run on a newly created cloud server and follow
some basic security guidelines. This script will do the following:

  1. Backup /etc directory to $backup.tar.gz
  2. Add a user ($username) and include them in sudo group
  3. Install curl, pwgen, ufw, latest updates
  4. Harden ssh
        Port=${SSH_SETTINGS[Port]}
        AllowUsers=${SSH_SETTINGS[AllowUsers]}
        LoginGraceTime=${SSH_SETTINGS[LoginGraceTime]}
        PermitRootLogin=${SSH_SETTINGS[PermitRootLogin]}
  5. Apply following rules to ubuntu firewall
        ufw default allow outgoing
        ufw default deny incoming
        ufw allow ${SSH_SETTINGS[Port]}/tcp
        ufw enable
  6. Create a settings file for future scripts to read
  7. Download file for preparing for the next stage
  8. REBOOT

NOTICE
test -z "$1" || echo "Logs can be found at ./$1"
}

press_enter_to_continue() {
    test -z "$1" && msg="Press any key to continue: " || msg="$1"
    read -p "$msg" dummy
}

ssh_port=52204
username=louser

while [ $# -gt 0 ]; do
    case $1 in
        -p|--port)
            ssh_port=$2
            shift
            shift
            ;;
        -u|--username)
            username=$2
            shift
            shift
            ;;
        -h|-help|--help)
            show_help
            what_it_does
            exit 0
            ;;
    esac
done

declare -A SSH_SETTINGS 
SSH_SETTINGS["Port"]=$ssh_port
SSH_SETTINGS["AllowUsers"]=$username
SSH_SETTINGS["LoginGraceTime"]=1m
SSH_SETTINGS["PermitRootLogin"]=no

stamp=$(date +%Y-%m-%d)
backup=/root/etc-backup-$stamp

what_it_does $stamp
press_enter_to_continue

mkdir ./$stamp
export DEBIAN_FRONTEND=noninteractive

# backup of /etc
printf "Creating backup - "
tar -zcf $backup.tar.gz /etc/ && echo "OK" || echo "Failed"

# create a user
printf "Adding user $username - \n"
(adduser -q $username && usermod -aG sudo $username) && echo "OK" || echo "Failed"

# install packages, upgrading system
printf "Running: apt-get update - "
apt-get update >> ./$stamp/apt-get-update.log  2>&1 && echo "OK" || echo "Failed" 

printf "Running: apt-get install ufw pwgen curl git - "
apt-get -y install ufw pwgen curl git >> ./$stamp/apt-get-y-install-ufw-pwgen-curl-git.log 2>&1 && echo "OK" || echo "Failed"

printf "Running: apt-get -u upgrade - "
apt-get -u -y upgrade >> ./$stamp/apt-get-u-y-upgrade.log 2>&1 && echo "OK" || echo "Failed"

printf "Running: apt-get autoremove - "
apt-get -y autoremove >> ./$stamp/apt-get-y-autoremove.log 2>&1 && echo "OK" || echo "Failed"

# ssh settings
sshd_file=/etc/ssh/sshd_config
cp $sshd_file ./$stamp/sshd_config.orig

echo "Updating ssh"
for setting in "${!SSH_SETTINGS[@]}"; do
    before=$(cat $sshd_file | grep -n "^#$setting")

    if [ $? -eq 0 ]; then
        value=$(cat $sshd_file | grep "^#$setting" | awk '{print $2}')
        sed -i "s:^#$setting $value:$setting ${SSH_SETTINGS[$setting]}:g" $sshd_file
    else
        before=$(cat $sshd_file | grep -n "^$setting")

        if [ $? -eq 0 ]; then
            value=$(cat $sshd_file | grep "^$setting" | awk '{print $2}')
            sed -i "s:^$setting $value:$setting ${SSH_SETTINGS[$setting]}:g" $sshd_file
        else
            echo "$setting ${SSH_SETTINGS[$setting]}" >> $sshd_file
        fi
    fi

    after=$(cat $sshd_file | grep -n "^$setting")

    printf "For $setting:\n\tbefore:\t$before\n\tafter:\t$after\n"
done

msg="Check ssh settings. If wrong, fix it yourself. To continue, press enter: "
press_enter_to_continue "$msg"

# if PasswordAuthentication was set to no, then copy authorized_keys file to $username's home dir
echo "Checking ssh for PasswordAuthentication"
check=$(cat $sshd_file | grep -n ^PasswordAuthentication)
if [ $? -eq 0 ]; then

    pa_value=$(cat $sshd_file | grep -n ^PasswordAuthentication | awk '{print $2}')

    echo " >> PasswordAuthentication: $pa_value"

    auth_check=$(cat $sshd_file | grep -n ^AuthorizedKeysFile)

    if [ $? -eq 0 ]; then
        auth_check_file=$(cat $sshd_file | grep -n ^AuthorizedKeysFile | awk '{print $2}')
        echo " >> AuthorizedKeysFile: $auth_check_file"
    else
        auth_check_file=.ssh/authorized_keys
        echo " >> AuthorizedKeysFile: $auth_check_file (using default)"
        #^ use the default file
    fi

    if [ "$pa_value" = "no" ]; then
        mkdir -p /home/$username/.ssh

        cp $HOME/$auth_check_file /home/$username/$auth_check_file

        chown -R $username:$username /home/$username/.ssh

        chmod 700 /home/$username/.ssh
        chmod 600 /home/$username/$auth_check_file

        echo " >> Copied $HOME/$auth_check_file  to /home/$username/$auth_check_file"
    else
        echo " >> No need for explicitly copying $auth_check_file"
    fi
else
    echo " >> PasswordAuthentication: $pa_value [skipping]"
fi

echo "Updating ufw rules"
ufw default allow outgoing
ufw default deny incoming
ufw allow ${SSH_SETTINGS[Port]}/tcp
ufw enable
ufw status

cat > ./$stamp/system-setup.conf << SYSTEM_SETUP
user=$username
ssh_port=${SSH_SETTINGS[Port]}
ssh_allowusers=${SSH_SETTINGS[AllowUsers]}
ssh_logingracetime=${SSH_SETTINGS[LoginGraceTime]}
ssh_permitrootlogin=${SSH_SETTINGS[PermitRootLogin]}
scripts_clonedir=/home/$username/scripts
scripts_setupdir=/home/$username/system-setup-$stamp
SYSTEM_SETUP

echo -n "Creating config file in /home/$username/.system-setup.conf: "
cp ./$stamp/system-setup.conf /home/$username/.system-setup.conf && echo "OK" || echo "Failed"

cat > ./$stamp/prepare-stage.sh << PREPARE_STAGE
#!/bin/bash
source /home/$username/.system-setup.conf
export \$(cut -d= -f1 /home/$username/.system-setup.conf)

cat << WHAT_IT_DOES
This script does the following:
 1. Generates ssh key using "ssh-keygen"
 2. Clones ashakunt/scripts.git from Github
 3. Creates log dir for all scripts (or tasks) that
    are run from the ashakunt/scripts.git repository

 If this script fails at any point, you might want to
 run that specific command again.
WHAT_IT_DOES

read -p "Press enter when you are ready: " dummy

echo "--------------Generating ssh key--------------"
ssh-keygen
echo "---------------------DONE---------------------"

echo "---------Cloning ashakunt/scripts.git---------"
git clone https://github.com/ashakunt/scripts.git /home/$username/scripts
echo "---------------------DONE---------------------"

echo "---------------Creating log dir---------------"
mkdir -p /home/$username/system-setup-$stamp
echo "---------------------DONE---------------------"

echo "If there were errors, please try again. Immediate next steps:   "
echo "    1. $ cd /home/$username/scripts"
echo "    2. $ ./02.do-run_2nd_on_droplet.sh"

PREPARE_STAGE

echo -n "Creating script for preparing next stage: "
(cp ./$stamp/prepare-stage.sh /home/$username/ && chmod +x /home/$username/prepare-stage.sh) && echo "OK" || echo "Failed"

server_ip=$(ifconfig eth0 | grep "inet " | awk {'print $2'})

echo "-----------------------------------------------------------------------------"
echo "Done. If there were any errors, we recommend to restore backup and try again."
echo
echo "For server login: ssh -p ${SSH_SETTINGS[Port]} $username@$server_ip"
echo "On next login, run this: $ prepare-stage.sh"

press_enter_to_continue "Press enter to reboot: " 

reboot
