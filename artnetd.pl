#! /usr/bin/perl -w

use strict;
use Config::Simple;
use Time::HiRes qw(usleep gettimeofday tv_interval);
use Redis;
use Storable qw(thaw);
use IO::Socket::INET;

use constant REDIS_HOST => 'redis';
use constant REDIS_PORT => '6379';
use constant REDIS_QUEUE_1_NAME => 'artnet_1:queue';
use constant REDIS_QUEUE_2_NAME => 'artnet_2:queue';
use constant ARTNET_CONF => 'artnet.conf';

my $config = new Config::Simple(ARTNET_CONF);

my $redis_host = REDIS_HOST;
my $redis_port = REDIS_PORT;
my $redis = Redis->new(
	server => "$redis_host:$redis_port",
) || warn $!;

my $timeout = 86400;

# Set up defaults
my $fps = $redis->get('fps') || 60; 
my $target_interval = 1.0 / $fps; # Target frame time in seconds (e.g., 0.016666 for 60fps)

my $should_exit = 0;
$SIG{TERM} = sub { print "$0 received SIGTERM\n"; $should_exit = 1 };
$SIG{KILL} = sub { print "$0 received SIGKILL\n"; $should_exit = 1 };
my $exit_countdown = $fps * ($config->param('cross_fade_time') || 2);

# flush after every write
$| = 1;

my $socket = IO::Socket::INET->new(
	PeerAddr => $config->param('peer_addr') . ":6454",
	Proto    => 'udp'
) || die "ERROR in socket creation : $!\n";

# Timekeeping variables
my $last_frame_time = [gettimeofday];
my $last_fps_check = time();

while (1) {
	my $now = [gettimeofday];
	
	# 1. EXACT TIMING CHECK: Has enough time passed to process the next frame?
	my $elapsed = tv_interval($last_frame_time, $now);
	
	if ($elapsed >= $target_interval) {
		# Update frame time anchor point
		$last_frame_time = $now;

		# 2. NON-BLOCKING FETCH: Grab the latest jobs instantly
		# We look at queue 1, then queue 2 immediately
		foreach my $queue (REDIS_QUEUE_1_NAME, REDIS_QUEUE_2_NAME) {
			my $job_id = $redis->lpop($queue); # Non-blocking LPOP
			if ($job_id) {
				my %data = $redis->hgetall($job_id);
				if ($data{message}) {
					my $frame = thaw($data{message});
					foreach (@$frame) {
						$socket->send($_); # Immediate UDP broadcast
					}
				}
				$redis->del($job_id);
			}
		}

		# 3. ONCE-PER-SECOND TASKS (Housekeeping)
		if (time() - $last_fps_check >= 1) {
			my $new_fps = $redis->get('fps') || 60;
			if ($new_fps != $fps) {
				$fps = $new_fps;
				$target_interval = 1.0 / $fps;
				print "Framerate updated smoothly to: $fps FPS\n";
			}
			$last_fps_check = time();
		}

		# Handle clean exit sequence
		if ($should_exit && $exit_countdown-- <= 0) {
			warn "$0 exiting cleanly\n";
			exit 0;
		}
	} else {
		# 4. CPU PROTECTOR: We are too early for the next frame.
		# Sleep for a tiny fraction of a millisecond (100-200 microseconds).
		# This gives the CPU core a breather without causing us to miss our frame window.
		usleep(200); 
	}
}
