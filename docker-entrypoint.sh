#!/bin/bash

service apache2 start
service redis-server start

# --- Wait for Redis to be ready ---
echo "Waiting for Redis to start..."
while ! redis-cli ping | grep -q "PONG"; do
    sleep 0.5
done
echo "Redis is ready!"

chown -R www-data:www-data /led_controller/data
cd /led_controller

terminate() {
	echo "sending SIGTERM to child processes"
	
	send_artnet_data_pid=$(pgrep -P $sudo_send_artnet_data_pid)
	kill -TERM "$send_artnet_data_pid" 2> /dev/null
	
	sleep 5;
		
	artnetd_pid=$(pgrep -P  $sudo_artnetd_pid)
	kill -TERM "$artnetd_pid" 2> /dev/null
}

trap terminate SIGTERM

./sun_tracker.pl &
sleep 5

sudo -u www-data ./send_artnet_data.pl &
sudo_send_artnet_data_pid=$!

sudo -u www-data ./artnetd.pl &
sudo_artnetd_pid=$!

sleep 5
./artnet_listener.pl &

wait "$sudo_send_artnet_data_pid"
wait "$sudo_artnetd_pid"
