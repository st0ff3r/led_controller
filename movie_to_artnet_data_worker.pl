#!/usr/bin/perl
use strict;
use Redis;
use LedController;

my $redis = Redis->new(server => 'redis:6379');
my $c = LedController->new();

# In movie_to_artnet_data_worker.pl
while (1) {
	my ($queue, $job_file) = $redis->blpop('job_queue', 0);
	
	$redis->set('system_locked', '1');
	# SET TO 50: Upload/Processing started
	$redis->set('progress', '50.0'); 
	$redis->publish('progress_channel', '50.0');

	if ($c->movie_to_artnet(
		movie_file => $job_file, 
		artnet_data_file => "/led_controller/data/artnet.data", 
		loop_forth_and_back => 1
	)) {
		$c->movie_to_slitscan(slitscan_file => "/var/www/led_controller/images/slitscan.png");
		
		# SET TO 100: Processed and ready for artnet sender
		$redis->set('progress', '100.0');
		$redis->publish('progress_channel', '100.0');
	} else {
		# ABORTED/FAILED: Reset
		$redis->set('progress', '0.0');
		$redis->publish('progress_channel', '0.0');
	}

	$c->cleanup_temp_files();
	unlink($job_file);
	# Important: Remove system_locked when the job is truly done
	$redis->del('system_locked');
}
