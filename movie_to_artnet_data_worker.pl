#!/usr/bin/perl
use strict;
use Redis;
use LedController;
use POSIX qw(SIGTERM SIGINT);

my $should_exit = 0;

# Define the Signal Handler
$SIG{TERM} = sub { $should_exit = 1; warn "[Worker] SIGTERM received. Shutting down gracefully...\n"; };
$SIG{INT}  = sub { $should_exit = 1; warn "[Worker] SIGINT received. Shutting down gracefully...\n"; };

my $redis = Redis->new(server => 'redis:6379');
my $c = LedController->new();

# Loop while we should NOT exit
while (! $should_exit) {
	# Use a 5-second timeout on blpop to allow periodic checking of $should_exit
	my $result = $redis->blpop('job_queue', 5);
	next unless $result;

	my ($queue, $job_file) = @$result;
	
	$redis->set('system_locked', '1');
	# SET TO 50: Upload/Processing started
	$redis->set('progress', '50.0'); 
	$redis->publish('progress_channel', '50.0');

	# Wrap job in eval to catch crashes and ensure system_locked is cleared
	eval {
		if ($c->movie_to_artnet(
			movie_file => $job_file, 
			artnet_data_file => "/led_controller/data/artnet.data", 
			loop_forth_and_back => 1
		)) {
			$c->movie_to_slitscan(slitscan_file => "/var/www/led_controller/images/slitscan.png");
	
			# Signal that everything is completely finished and written to disk
			$redis->set('progress', '-1.0');
			$redis->publish('progress_channel', '-1.0');
		} else {
			die "Conversion failed";
		}
	};

	if ($@) {
		warn "[Worker] Job failed: $@";
		$redis->set('progress', '0.0');
		$redis->publish('progress_channel', '0.0');
	}

	unlink($job_file) if -e $job_file;
	# Important: Remove system_locked when the job is truly done
	$redis->del('system_locked');
}

warn "[Worker] Exited cleanly.\n";
