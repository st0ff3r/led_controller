#!/bin/bash
# Enable job control
set -m

# Ensure PERL5LIB is exported globally so you don't have to re-type it
export PERL5LIB=/led_controller

# Start Apache
apachectl start

# Fix permissions
chown -R www-data:www-data /led_controller/data
cd /led_controller

# Function to handle clean shutdown
terminate() {
	echo "Sending SIGTERM to child processes..."
	pkill -P $$
	exit 0
}
trap terminate SIGTERM

# Start scripts
# Note: Since PERL5LIB is exported above, it passes through to background tasks natively.
# We redirect stderr (2) to stdout (1) so Docker logs catch everything.

./sun_tracker.pl 2>&1 &
sleep 5

sudo -E -u www-data ./movie_to_artnet_data_worker.pl 2>&1 &
movie_to_artnet_data_worker_pid=$!

sudo -E -u www-data ./send_artnet_data.pl 2>&1 &
sudo_send_artnet_data_pid=$!

sudo -E -u www-data ./artnetd.pl 2>&1 &
sudo_artnetd_pid=$!

sleep 5
./artnet_listener.pl 2>&1 &

# Keep the entrypoint running and monitoring background processes
wait
