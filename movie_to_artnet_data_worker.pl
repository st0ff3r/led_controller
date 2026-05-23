#!/usr/bin/perl
use strict;
use Redis;
use LedController;

my $redis = Redis->new(server => '127.0.0.1:6379');
my $c = LedController->new();

while (1) {
	my ($queue, $job_file) = $redis->blpop('job_queue', 0);
	
	$redis->set('system_locked', '1');
	$redis->set('progress', '0.0'); 

	if ($c->movie_to_artnet(
		movie_file => $job_file, 
		artnet_data_file => "/led_controller/data/artnet.data", 
		loop_forth_and_back => 1
	)) {
		$c->movie_to_slitscan(slitscan_file => "/var/www/led_controller/images/slitscan.png");
	}

	$c->cleanup_temp_files();
	unlink($job_file);
}
