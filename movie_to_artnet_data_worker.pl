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
	# Wrap job in eval to catch crashes
	eval {
		warn "[Worker] Running ArtNet Conversion...\n";
		my $artnet_ok = $c->movie_to_artnet(
			movie_file => $job_file, 
			artnet_data_file => "/led_controller/data/artnet.data",
			loop_forth_and_back => 1
		);

		warn "[Worker] Running Slitscan Generation...\n";
		my $slitscan_ok = $c->movie_to_slitscan(
			movie_file => $job_file, 
			slitscan_file => "/var/www/led_controller/images/slitscan.png"
		);

		if ($artnet_ok && $slitscan_ok) {
			# Signal that everything is completely finished and written to disk
			$redis->set('progress', '-1.0');
			$redis->publish('progress_channel', '-1.0');
			warn "[Worker] Job finished successfully.\n";
		} else {
			warn "[Worker] A process failed, but moving to next job...\n";
			$redis->set('progress', '0.0');
			$redis->publish('progress_channel', '0.0');
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
