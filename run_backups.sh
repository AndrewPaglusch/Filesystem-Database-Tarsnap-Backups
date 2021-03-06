#!/bin/bash

###################################################################################################################################################################################
#Backup databases for PostgreSQL and MySQL/MariaDB

BACKUPDEST=/opt/backups/database_dumps
FILELIST=/opt/backups/filelist.txt

# Path to tarsnap
TARSNAP="/usr/local/bin/tarsnap"

install_tarsnap ()
{
	yum -y install gcc e2fsprogs-devel zlib-devel openssl-devel wget
	TEMPDIR=$(mktemp -d)
	echo $TEMPDIR
	wget -O $TEMPDIR/tarsnap.tgz https://www.tarsnap.com/download/tarsnap-autoconf-1.0.37.tgz
	tar -xvf $TEMPDIR/tarsnap.tgz -C $TEMPDIR
	(cd $TEMPDIR/tarsnap-autoconf-* && ./configure)
	(cd $TEMPDIR/tarsnap-autoconf-* && make install clean)
	tarsnap --version
	rm -rf $TEMPDIR
	mv /usr/local/etc/tarsnap.conf.sample /usr/local/etc/tarsnap.conf
	sed -i "s|keyfile\ \/root\/tarsnap.key|keyfile\ \/opt\/backups\/tarsnap.key|g" /usr/local/etc/tarsnap.conf
	tarsnap-keygen --keyfile /opt/backups/tarsnap.key --user <<YOUR_TARSNAP_EMAIL_HERE>> --machine $(hostname)
}

dumpdb_mysql ()
{
	local DB=$1
	local CONF=$2

	if (mysqldump --defaults-file=$CONF --force --opt --databases $DB > $BACKUPDEST/MySQL/$DB.sql 2>/dev/null); then
		echo "Successfully backed up $DB to $BACKUPDEST/MySQL"
                ls -blarth "$BACKUPDEST/MySQL/$DB.sql"
        else
                echo "Failed to back up $DB to $BACKUPDEST/MySQL"
        fi
}

dumpdb_postgresql ()
{
	local DB=$1
	if (su - postgres -c "pg_dump $DB" > $BACKUPDEST/PostgreSQL/$DB.sql 2>/dev/null); then
		echo "Successfully backed up $DB to $BACKUPDEST/PostgreSQL"
                ls -blarth "$BACKUPDEST/PostgreSQL/$DB.sql"
        else
                echo "Failed to back up $DB to $BACKUPDEST/PostgreSQL"
        fi
}

#Make sure the needed directories exist
mkdir -p $BACKUPDEST/{MySQL,PostgreSQL}

#Make sure the filelist is in place. If not, create it
if ! [ -f $FILELIST ]; then
	echo "Missing/Empty 'filelist.txt' file. Continuing with Local database backups only. No off-site backups"
fi

if ! $(su - postgres -c "hash postgres 2>/dev/null"); then
        echo "Postgres is not installed. Skipping PostgreSQL backups..."
else
        echo "Starting backups for PostgreSQL..."
        DATABASES_POSTGRESQL=$(su - postgres -c "psql -q -t -c 'SELECT datname from pg_database'" | sed '/^$/d' | grep -v template0)
        for i in $DATABASES_POSTGRESQL; do
                echo "Working on '$i'..."
                dumpdb_postgresql $i
                echo
        done
fi

if ! hash "mysql" >/dev/null 2>&1; then
        echo "MySQL/MariaDB is not installed. Skipping MySQL backups..."
else
	echo "Starting backups for MySQL/MariaDB..."
	DATABASES_MYSQL=$(mysql -Be "show databases" | grep -vE '^Database$|^(information|performance)_schema$')
	DBCONF_MYSQL=/root/.my.cnf
	for i in $DATABASES_MYSQL; do
                echo "Working on '$i'..."
                dumpdb_mysql $i $DBCONF_MYSQL
                echo
	done
fi

if ! [ -f $TARSNAP ]; then
        echo "Tarsnap is not installed. Would you like to install TarSnap?"
        echo "You must ALREADY have an account created at tarsnap.com to proceed."
	read -p "Install? (Y/N): " choice
	case "$choice" in 
 		y|Y ) install_tarsnap ;;
		n|N ) echo "Exiting..."; exit 1;;
  		* ) echo "Invalid response. Exiting..."; exit 1;;
	esac
	
	if ! [ -f $TARSNAP ]; then echo "TarSnap install failed. Exiting.."; exit 1; fi
fi

###################################################################################################################################################################################
#Send backups to TarSnap

# Tarsnap backup script
# Written by Tim Bishop, 2009 - http://www.bishnet.net/tim/blog/2009/01/28/automating-tarsnap-backups/

# Prepend this to name of each backup
# This will get web01 from a hostname of web01.bla.bla.bla.com
HOSTNAME=$(hostname | cut -d'.' -f1)

# Directories to backup (sed strips comments and blank lines)
# Checks each file/dir to make sure it exists first
function check_exist()
{
        if [ -f "$1" ]; then return 0; fi
        if [ -d "$1" ]; then return 0; fi
        return 1
}

FILELISTCONTENTS=$(sed -e '/\s*#.*$/d' -e '/^\s*$/d' $FILELIST)

DIRS=""
for i in $FILELISTCONTENTS; do
        if check_exist "$i"; then DIRS+=" $i"; fi
done

# Number of daily backups to keep
DAILY=7

# Number of weekly backups to keep
WEEKLY=4

# Which day to do weekly backups on
# 1-7, Monday = 1
WEEKLY_DAY=1

# Number of monthly backups to keep
MONTHLY=3

# Which day to do monthly backups on
# 01-31 (leading 0 is important)
MONTHLY_DAY=01

# end of config

# day of week: 1-7, monday = 1
DOW=$(date +%u)
# day of month: 01-31
DOM=$(date +%d)
# month of year: 01-12
MOY=$(date +%m)
# year
YEAR=$(date +%Y)
# time
TIME=$(date +%H%M%S)

# Backup name
if [ X"$DOM" = X"$MONTHLY_DAY" ]; then
	# monthly backup
	BACKUP="$HOSTNAME-$YEAR$MOY$DOM-$TIME-monthly"
elif [ X"$DOW" = X"$WEEKLY_DAY" ]; then
	# weekly backup
	BACKUP="$HOSTNAME-$YEAR$MOY$DOM-$TIME-weekly"
else
	# daily backup
	BACKUP="$HOSTNAME-$YEAR$MOY$DOM-$TIME-daily"
fi

# Do backups
for dir in $DIRS; do
	EXTRA_FLAGS="--print-stats --humanize-numbers"
	
	echo "==> create $BACKUP-$dir"
	$TARSNAP $EXTRA_FLAGS -c -f $BACKUP-$dir $dir
done

# Backups done, time for cleaning up old archives

# using tail to find archives to delete, but its
# +n syntax is out by one from what we want to do
# (also +0 == +1, so we're safe :-)
DAILY=`expr $DAILY + 1`
WEEKLY=`expr $WEEKLY + 1`
MONTHLY=`expr $MONTHLY + 1`

# Do deletes
TMPFILE=/tmp/tarsnap.archives.$$
$TARSNAP --list-archives > $TMPFILE
DELARCHIVES=""
for dir in $DIRS; do
	for i in `grep -E "^$HOSTNAME-[[:digit:]]{8}-[[:digit:]]{6}-daily-$dir$" $TMPFILE | sort -rn | tail -n +$DAILY`; do
		echo "==> delete $i"
		DELARCHIVES="$DELARCHIVES -f $i"
	done
	for i in `grep -E "^$HOSTNAME[[:digit:]]{8}-[[:digit:]]{6}-weekly-$dir$" $TMPFILE | sort -rn | tail -n +$WEEKLY`; do
		echo "==> delete $i"
		DELARCHIVES="$DELARCHIVES -f $i"
	done
	for i in `grep -E "^$HOSTNAME-[[:digit:]]{8}-[[:digit:]]{6}-monthly-$dir$" $TMPFILE | sort -rn | tail -n +$MONTHLY`; do
		echo "==> delete $i"
		DELARCHIVES="$DELARCHIVES -f $i"
	done
done
if [ X"$DELARCHIVES" != X ]; then
	echo "==> delete $DELARCHIVES"
	$TARSNAP -d $DELARCHIVES
fi

rm $TMPFILE
