#! /usr/bin/perl -w

use strict;
use Config::Simple;
use Time::HiRes qw(ualarm gettimeofday tv_interval);
use Redis;
use IO::Socket::INET;

use constant REDIS_QUEUE_1_NAME => 'artnet_1:queue';
use constant REDIS_QUEUE_2_NAME => 'artnet_2:queue';
use constant ARTNET_CONF => 'artnet.conf';

# Every individual Art-Net DMX universe packet generated is exactly 530 bytes 
# (18 byte protocol header + 512 byte channel payload)
use constant PACKET_SIZE => 530; 

my $config = new Config::Simple(ARTNET_CONF);

my $redis_socket = $ENV{REDIS_SOCKET} || die "REDIS_SOCKET environment variable not set";
my $redis = Redis->new(sock => $redis_socket) or die "Failed to connect to Redis socket: $!";

my $timeout = 86400;

# Set up defaults
my $fps = $redis->get('fps') || 60; 

# Interrupt interval tracking state (converted to microseconds for ualarm)
my $target_interval_usec = int(1_000_000 / $fps);

my $should_exit = 0;
$SIG{TERM} = sub { print "$0 received SIGTERM\n"; $should_exit = 1 };
$SIG{KILL} = sub { print "$0 received SIGKILL\n"; $should_exit = 1 };
my $exit_countdown = $fps * ($config->param('cross_fade_time') || 2);

$| = 1;

my $socket = IO::Socket::INET->new(
	PeerAddr => $config->param('peer_addr') . ":6454",
	Proto    => 'udp'
) || die "ERROR in socket creation : $!\n";

my $last_fps_check = time();

# 1. THE INTERRUPT FLAG
my $frame_tick = 0;

# 2. THE TIMER INTERRUPT REGISTER
# When the OS fires a SIGALRM signal, pause everything and increment our flag instantly
$SIG{ALRM} = sub {
	$frame_tick++;
};

# 3. ARM THE TICK GENERATOR
# ualarm(initial_delay_usec, repeating_interval_usec)
ualarm($target_interval_usec, $target_interval_usec);

print "Art-Net Daemon initialized via OS Timer Interrupts ($fps FPS / Interval: $target_interval_usec usec)\n";

while (1) {
	# 4. SLEEP UNTIL NEXT INTERRUPT WAKES US UP
	# sleep() or select() blocks the process from consuming CPU cycles.
	# Any native OS signal (like our SIGALRM) immediately breaks this sleep block.
	select(undef, undef, undef, 1.0);

	# 5. PROCESS TICKS ACCUMULATED
	while ($frame_tick > 0) {
		$frame_tick--; # Consume the tick

		# Fetch jobs from the queues
		foreach my $queue (REDIS_QUEUE_1_NAME, REDIS_QUEUE_2_NAME) {
			my $job_id = $redis->lpop($queue);
			if ($job_id) {
				my %data = $redis->hgetall($job_id);
				if ($data{message}) {
					while ($data{message} =~ /(.{1,530})/sg) {
						$socket->send($1);
					}
				}
				$redis->del($job_id);
			}
		}

		# Once-per-second tasks
		if (time() - $last_fps_check >= 1) {
			my $new_fps = $redis->get('fps') || 60;
			if ($new_fps != $fps) {
				$fps = $new_fps;
				$target_interval_usec = int(1_000_000 / $fps);
				
				# PRECISE RE-ARM: Stop timer first to avoid race conditions on execution context
				ualarm(0, 0);
				ualarm($target_interval_usec, $target_interval_usec);
				print "Framerate updated smoothly via interrupt register to: $fps FPS\n";
				
				# Force loop to immediately evaluate new timing cadence
				last;
			}
			$last_fps_check = time();
		}

		# Handle clean exit sequence
		if ($should_exit && $exit_countdown-- <= 0) {
			ualarm(0, 0); # Disarm timer completely
			warn "$0 exiting cleanly\n";
			exit 0;
		}
	}
}
