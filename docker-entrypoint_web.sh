#!/bin/bash
set -e

# 1. Clean up stale Apache PID files if they exist (common cause of restart errors)
if [ -f /var/run/apache2/apache2.pid ]; then
	rm -f /var/run/apache2/apache2.pid
fi

# 2. Source the Apache environment variables
source /etc/apache2/envvars

# 3. Start Apache in the foreground
# Exec replaces this shell script with the apache2 process, 
# ensuring signals go directly to Apache.
exec /usr/sbin/apache2 -D FOREGROUND
