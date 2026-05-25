#!/bin/bash
set -e

# 1. Clean up stale Apache PID files if they exist (common cause of restart errors)
if [ -f /var/run/apache2/apache2.pid ]; then
	rm -f /var/run/apache2/apache2.pid
fi

# 2. Guarantee the runtime tmp directory exists inside the shared volume
#    and is owned by the Apache user (www-data)
if [ ! -d "/led_controller/data/tmp" ]; then
	mkdir -p /led_controller/data/tmp
fi
chown -R www-data:www-data /led_controller/data/tmp

# 3. Source the Apache environment variables
source /etc/apache2/envvars

# 4. Start Apache in the foreground
# Exec replaces this shell script with the apache2 process, 
# ensuring signals go directly to Apache.
exec /usr/sbin/apache2 -D FOREGROUND
