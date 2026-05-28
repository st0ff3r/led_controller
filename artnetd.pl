#! /usr/bin/perl -w

use strict;
use Config::Simple;
use Time::HiRes qw(ualarm gettimeofday tv_interval);
use Redis;
use IO::Socket::INET;

use constant REDIS_HOST => 'redis';
use constant REDIS_PORT => '6379';
use constant REDIS_QUEUE_1_NAME => 'artnet_1:queue';
use constant REDIS_QUEUE_2_NAME => 'artnet_2:queue';
use constant ARTNET_CONF => 'artnet.conf';

# Every individual Art-Net DMX universe packet generated is exactly 530 bytes 
# (18 byte protocol header + 512 byte channel payload)
use constant PACKET_SIZE => 530; 

# Defensive Limits: Prevent OS signal buffer saturation
use constant MIN_SANITY_FPS => 1;
use constant MAX_SANITY_FPS => 120; 

my $config = new Config::Simple(ARTNET_CONF);

my $redis_host = REDIS_HOST;
my $redis_port = REDIS_PORT;
my $redis = Redis->new(
	server => "$redis_host:$redis_port",
) || warn $!;

# --- LUA SCRIPT ENGINE REGISTER (CORRECTED) ---
# Separately pops from each queue to prevent the mirror channel from being eaten by the frame skipper.
my $lua_pop_and_flush = qq{
    local data1 = nil
    local data2 = nil

    -- Process Queue 1
    local job_id1 = redis.call('LPOP', KEYS[1])
    if job_id1 then
        local next_id = redis.call('LPOP', KEYS[1])
        while next_id do
            redis.call('DEL', job_id1)
            job_id1 = next_id
            next_id = redis.call('LPOP', KEYS[1])
        end
        data1 = redis.call('HGET', job_id1, 'message')
        redis.call('DEL', job_id1)
    end

    -- Process Queue 2
    local job_id2 = redis.call('LPOP', KEYS[2])
    if job_id2 then
        local next_id = redis.call('LPOP', KEYS[2])
        while next_id do
            redis.call('DEL', job_id2)
            job_id2 = next_id
            next_id = redis.call('LPOP', KEYS[2])
        end
        data2 = redis.call('HGET', job_id2, 'message')
        redis.call('DEL', job_id2)
    end

    -- Return both payloads separated by a delimiter if both exist
    return {data1, data2}
};

my $lua_sha = $redis->script_load($lua_pop_and_flush);
# ----------------------------------

my $timeout = 86400;

# Set up defaults with defensive compliance limits
my $initial_fps = $redis->get('fps') || 60; 
if ($initial_fps < MIN_SANITY_FPS) { $initial_fps = MIN_SANITY_FPS; }
if ($initial_fps > MAX_SANITY_FPS) { $initial_fps = MAX_SANITY_FPS; }

my $fps = $initial_fps;

# Interrupt interval tracking state (converted to microseconds for ualarm)
my $target_interval_usec = int(1_000_000 / $fps);

my $should_exit = 0;
$SIG{TERM} = sub { print "$0 received SIGTERM\n"; $should_exit = 1 };
$SIG{KILL} = sub { print "$0 received SIGKILL\n"; $should_exit = 1 };
my $exit_countdown = $fps * ($config->param('cross_fade_time') || 2);

# flush after every write
$| = 1;

# network connection
my $socket = IO::Socket::INET->new(
	PeerAddr => $config->param('peer_addr') . ":6454",
	Proto    => 'udp'
) || die "ERROR in socket creation : $!\n";

my $last_fps_check = time();
my $dropped_frame_counter = 0; # Non-blocking lag tracking register

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
	if ($frame_tick > 0) {
		
		# DYNAMIC FRAME DROPPER:
		# If $frame_tick is > 1, the hardware timer fired again before we finished 
		# processing the previous interval. Accumulate the lag in RAM instead of blocking on logs.
		if ($frame_tick > 1) {
			$dropped_frame_counter += ($frame_tick - 1);
		}

		$frame_tick = 0; # Consume the ticks instantly

		# Execute atomic Lua extraction (Handing both queue names as Redis KEYS)
		my $binary_frame = $redis->evalsha($lua_sha, 2, REDIS_QUEUE_1_NAME, REDIS_QUEUE_2_NAME);
		
		if ($binary_frame) {
			# Split the concatenated payload into 530-byte chunks 
			# directly out of memory and stream them over UDP.
			while ($binary_frame =~ /(.{1,530})/sg) {
				$socket->send($1);
			}
		}

		# Once-per-second tasks
		if (time() - $last_fps_check >= 1) {
			
			# Safe deferred logging block out of the time-critical loop context
			if ($dropped_frame_counter > 0) {
				warn "[artnetd] Warning: CPU lag detected. Dropped $dropped_frame_counter frame(s) in the last second to maintain sync.\n";
				$dropped_frame_counter = 0;
			}

			my $raw_fps = $redis->get('fps') || 60;
			
			# Apply defensive compliance guards to incoming Redis value
			if ($raw_fps < MIN_SANITY_FPS) { $raw_fps = MIN_SANITY_FPS; }
			if ($raw_fps > MAX_SANITY_FPS) { $raw_fps = MAX_SANITY_FPS; }

			if ($raw_fps != $fps) {
				$fps = $raw_fps;
				$target_interval_usec = int(1_000_000 / $fps);
				
				# PRECISE RE-ARM: Stop timer first to avoid race conditions on execution context
				ualarm(0, 0);
				ualarm($target_interval_usec, $target_interval_usec);
				print "Framerate updated smoothly via interrupt register to: $fps FPS\n";
				
				# Clear any backlog buildup from the old timing profile 
				# acting as a circuit breaker against signal queue overflow
				$frame_tick = 0;
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
