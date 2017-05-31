#!/bin/bash

###################################################################################################################################################################################
#Backup databases for each site to disk

DATABASES=$(mysql -Be "show databases" | grep -vE '^Database$|^(information|performance)_schema$')
BACKUPDEST=/opt/backups/database_dumps
DBCONF=/root/.my.cnf

dumpdb ()
{
	DB=$1
	if (mysqldump --defaults-file=$DBCONF --force --opt --databases $DB > $BACKUPDEST/$DB.sql 2>/dev/null); then
		echo "Successfully backed up $DB to $BACKUPDEST"
                ls -blarth "$BACKUPDEST/$DB.sql"
        else
                echo "Failed to back up $DB to $BACKUPDEST"
        fi
}

#Backup each database
for i in $DATABASES; do
	echo "Working on '$i'..."
	dumpdb $i
	echo
done

###################################################################################################################################################################################
#Send backups to TarSnap

# Tarsnap backup script
# Written by Tim Bishop, 2009 - http://www.bishnet.net/tim/blog/2009/01/28/automating-tarsnap-backups/

# Prepend this to name of each backup
HOSTNAME="web03"

# Directories to backup
DIRS=$(cat filelist.txt)

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

# Path to tarsnap
TARSNAP="/usr/local/bin/tarsnap"

# end of config

# day of week: 1-7, monday = 1
DOW=`date +%u`
# day of month: 01-31
DOM=`date +%d`
# month of year: 01-12
MOY=`date +%m`
# year
YEAR=`date +%Y`
# time
TIME=`date +%H%M%S`

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
