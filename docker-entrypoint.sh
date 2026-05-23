#!/bin/bash
# Enable job control
set -m

# Ensure PERL5LIB is exported for this script and its future children
export PERL5LIB=/led_controller

# Start services
apachectl start

chown -R www-data:www-data /led_controller/data
cd /led_controller

# Function to handle clean shutdown
terminate() {
	echo "sending SIGTERM to child processes"
	pkill -P $$
	exit
}
trap terminate SIGTERM

# Start scripts
# PERL5LIB is explicitly set before each command to ensure visibility 
# Output is redirected to /proc/1/fd/1 (stdout) and /proc/1/fd/2 (stderr)

PERL5LIB=/led_controller ./sun_tracker.pl > /proc/1/fd/1 2>&1 &
sleep 5

sudo -u www-data PERL5LIB=/led_controller ./movie_to_artnet_data_worker.pl > /proc/1/fd/1 2>&1 &
movie_to_artnet_data_worker_pid=$!

sudo -u www-data PERL5LIB=/led_controller ./send_artnet_data.pl > /proc/1/fd/1 2>&1 &
sudo_send_artnet_data_pid=$!

sudo -u www-data PERL5LIB=/led_controller ./artnetd.pl > /proc/1/fd/1 2>&1 &
sudo_artnetd_pid=$!

sleep 5
PERL5LIB=/led_controller ./artnet_listener.pl > /proc/1/fd/1 2>&1 &

# Keep the entrypoint running by waiting for background processes
wait
