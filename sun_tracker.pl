#!/usr/bin/perl -w

use strict;
$| = 1; # Force autoflush
use Config::Simple;
use DateTime;
use DateTime::Event::Sunrise;
use DateTime::Duration;
use IO::Async::Timer::Periodic;
use IO::Async::Loop;
use Redis;
use Data::Dumper;
use feature 'state'; # Enabled to allow persistent local variables

use constant ARTNET_CONF => 'artnet.conf';

my $config = new Config::Simple(ARTNET_CONF);

my $redis_socket = $ENV{REDIS_SOCKET} || die "REDIS_SOCKET environment variable not set";
my $redis = Redis->new(sock => $redis_socket) or die "Failed to connect to Redis socket: $!";

my $loop = IO::Async::Loop->new;

# Register signal handlers to trigger graceful loop shutdown
$loop->watch_signal( 'TERM', sub { 
	warn "[Sunrise] SIGTERM received. Stopping loop...\n"; 
	$loop->stop; 
});

$loop->watch_signal( 'INT', sub { 
	warn "[Sunrise] SIGINT received. Stopping loop...\n"; 
	$loop->stop; 
});

# Properly declare and initialize $timer
my $timer = IO::Async::Timer::Periodic->new(
	interval => 1,
	on_tick => \&do_calculation
);

$timer->start;
$loop->add($timer);

# Start the event loop
$loop->run;

# Cleanup after the loop has stopped
warn "[Sunrise] Loop exited. Cleaning up...\n";
$redis->quit;

sub do_calculation {
	state $last_logged_state = ''; # Keeps track of the last state to avoid log flooding
	state $tick_count = 0;         # Tracks ticks for transition intervals
	
	my $sunrise_start = DateTime::Event::Sunrise->sunrise(longitude => 12.5683, latitude => 55.6761, altitude => -6);
	my $sunrise_end = DateTime::Event::Sunrise->sunrise(longitude => 12.5683, latitude => 55.6761, altitude => -0.833);
	my $sunset_start = DateTime::Event::Sunrise->sunset(longitude => 12.5683, latitude => 55.6761, altitude => -0.833);
	my $sunset_end = DateTime::Event::Sunrise->sunset(longitude => 12.5683, latitude => 55.6761, altitude => -6);
	
	my $dt_now = DateTime->now(time_zone => 'Europe/Copenhagen');
	my $now = $dt_now->epoch;
	
	my $current_rise_start = $sunrise_start->current($dt_now)->epoch;
	my $current_rise_end = $sunrise_end->current($dt_now)->epoch;
	my $current_set_start = $sunset_start->current($dt_now)->epoch;
	my $current_set_end = $sunset_end->current($dt_now)->epoch;
	
	# find the sun state
	my $elapsed_time;
	my $state = 'up';
	$elapsed_time = $now - $current_rise_end;
	
	$_ = $now - $current_set_start;
	if ($_ < $elapsed_time) {
		$state = 'setting';
		$elapsed_time = $_;
	}
	$_ = $now - $current_set_end;
	if ($_ < $elapsed_time) {
		$state = 'down';
		$elapsed_time = $_;
	}
	$_ = $now - $current_rise_start;
	if ($_ < $elapsed_time) {
		$state = 'rising';
		$elapsed_time = $_;
	}
	
	# --- Logging Logic ---
	my $time_str = $dt_now->hms;
	my $calculated_intensity = 0.0;

	if ($state eq 'up') {
		$calculated_intensity = 0.0;
		if ($last_logged_state ne 'up') {
			warn "[$time_str][Sunrise] State changed to: UP (Daytime). Setting intensity to 0.0\n";
			$last_logged_state = 'up';
		}
		set_intensity($calculated_intensity);
	}
	elsif ($state eq 'setting') {
		my $next_set_end = $sunset_end->next($dt_now)->epoch;
		my $dur = $next_set_end - $current_set_start;
		$calculated_intensity = $elapsed_time * (1 / $dur);
		
		# Log immediately on state change, otherwise throttle to every 10th tick
		if ($last_logged_state ne 'setting') {
			warn "[$time_str][Sunrise] State changed to: SETTING\n";
			$tick_count = 0; # Reset counter on entering new state
			$last_logged_state = 'setting';
		}
		
		if ($tick_count % 10 == 0) {
			warn sprintf("[$time_str][Sunrise] Progress: %d/%ds | Calculated Intensity: %.4f\n", 
				$elapsed_time, $dur, $calculated_intensity);
		}
		$tick_count++;
		
		set_intensity($calculated_intensity);
	}
	elsif ($state eq 'down') {
		$calculated_intensity = 1.0;
		if ($last_logged_state ne 'down') {
			warn "[$time_str][Sunrise] State changed to: DOWN (Nighttime). Setting intensity to 1.0\n";
			$last_logged_state = 'down';
		}
		set_intensity($calculated_intensity);
	}
	elsif ($state eq 'rising') {
		my $next_rise_end = $sunrise_end->next($dt_now)->epoch;
		my $dur = $next_rise_end - $current_rise_start;
		$calculated_intensity = 1 - ($elapsed_time * (1 / $dur));
		
		# Log immediately on state change, otherwise throttle to every 10th tick
		if ($last_logged_state ne 'rising') {
			warn "[$time_str][Sunrise] State changed to: RISING\n";
			$tick_count = 0; # Reset counter on entering new state
			$last_logged_state = 'rising';
		}
		
		if ($tick_count % 10 == 0) {
			warn sprintf("[$time_str][Sunrise] Progress: %d/%ds | Calculated Intensity: %.4f\n", 
				$elapsed_time, $dur, $calculated_intensity);
		}
		$tick_count++;
		
		set_intensity($calculated_intensity);
	}
}

sub set_intensity {
	my $intensity = shift;
	
	# Update Redis
	$redis->set('intensity', $intensity);
	
	# Publish to trigger send_artnet_data to refresh
	$redis->publish('intensity_update', 'refresh');
}

1;
