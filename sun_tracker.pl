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

use constant ARTNET_CONF => 'artnet.conf';

my $config = new Config::Simple(ARTNET_CONF);
my $redis = Redis->new(server => 'redis:6379');

my $loop = IO::Async::Loop->new;

my $timer = IO::Async::Timer::Periodic->new(
	interval => 1,
	on_tick => \&do_calculation
);

$timer->start;
 
$loop->add($timer);
 
$loop->run;

sub do_calculation {
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
	
	if ($state eq 'up') {
		set_intensity(0.0);
	}
	elsif ($state eq 'setting') {
		my $next_set_end = $sunset_end->next($dt_now)->epoch;
		my $dur = $next_set_end - $current_set_start;
		set_intensity($elapsed_time * (1 / $dur));
	}
	elsif ($state eq 'down') {
		set_intensity(1.0);
	}
	elsif ($state eq 'rising') {
		my $next_rise_end = $sunrise_end->next($dt_now)->epoch;
		my $dur = $next_rise_end - $current_rise_start;
		set_intensity(1 - ($elapsed_time * (1 / $dur)));
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
