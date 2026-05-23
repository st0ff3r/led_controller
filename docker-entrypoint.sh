#!/bin/bash

# Ensure PERL5LIB is exported for any sub-processes
export PERL5LIB=/led_controller

service apache2 start
service redis-server start

chown -R www-data:www-data /led_controller/data
cd /led_controller

terminate() {
	echo "sending SIGTERM to child processes"
	
	# Attempt to kill children
	[ ! -z "$sudo_send_artnet_data_pid" ] && pkill -P "$sudo_send_artnet_data_pid"
	[ ! -z "$sudo_artnetd_pid" ] && pkill -P "$sudo_artnetd_pid"
	
	sleep 5
		
	# Kill workers
	kill $movie_to_artnet_data_worker_pid 2> /dev/null
}

trap terminate SIGTERM

# Start processes as www-data with explicit PERL5LIB injection
./sun_tracker.pl &
sleep 5

sudo -u www-data PERL5LIB=/led_controller ./movie_to_artnet_data_worker.pl &
movie_to_artnet_data_worker_pid=$!

sudo -u www-data PERL5LIB=/led_controller ./send_artnet_data.pl &
sudo_send_artnet_data_pid=$!

sudo -u www-data PERL5LIB=/led_controller ./artnetd.pl &
sudo_artnetd_pid=$!

sleep 5
./artnet_listener.pl &

wait "$sudo_send_artnet_data_pid"
wait "$sudo_artnetd_pid"
