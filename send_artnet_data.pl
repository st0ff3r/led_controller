#!/usr/bin/perl -w

use strict;
use Time::HiRes qw(usleep gettimeofday tv_interval);
use Config::Simple;
use IPC::ShareLite;
use Data::Dumper;
use Redis;

use LedController::Artnet;

use constant ARTNET_CONF => '/led_controller/artnet.conf';

$| = 1; # Force autoflush

my $config = new Config::Simple(ARTNET_CONF);
my $redis = Redis->new(server => 'redis:6379');
my $artnet_data_file = $ARGV[0] || "data/artnet.data";
my $artnet_data = '';
my $new_artnet_data = '';

my $intensity = 0.0;
my $intensity_artnet = 0.0;
my $cross_fade_intensity = 0.0;
my $cross_fade_state = 'fade_in';
my $fps = 0;

my $cross_fade_time = $config->param('cross_fade_time') || 2;
my $cross_fade_per_step = 0.0;

my $share_intensity = IPC::ShareLite->new(
	-key		=> 6454,
	-create		=> 'yes',
	-destroy	=> 'yes'
) or die $!;

my $share_intensity_artnet = IPC::ShareLite->new(
	-key		=> 6455,
	-create		=> 'yes',
	-destroy	=> 'yes'
) or die $!;

# network connection
my $artnet = new LedController::Artnet(
	peer_addr => $config->param('peer_addr'),
	pixel_format => $config->param('pixel_format') || 'GRBW',
	num_channels_per_pixel => $config->param('num_channels_per_pixel') || 4,
	num_pixels => $config->param('num_pixels') || 300,
	universes_per_port => $config->param('universes_per_port') || 3,
	is_mirrored_on_first_port => $config->param('is_mirrored_on_first_port'),
	is_mirrored_on_second_port => $config->param('is_mirrored_on_second_port')
);

$SIG{USR1} = sub {
	$intensity = $share_intensity->fetch;
	$intensity_artnet = $share_intensity_artnet->fetch;
};

my $should_exit = 0;
$SIG{TERM} = sub { print "$0 received SIGTERM\n"; $cross_fade_state = 'fade_out'; $should_exit = 1 };
$SIG{KILL} = sub { print "$0 received SIGKILL\n"; $cross_fade_state = 'fade_out'; $should_exit = 1 };

my @pixel_line;
my ($red, $green, $blue);

# Wait until the data file exists and has content
print "Waiting for artnet data file: $artnet_data_file\n";
while (!-e $artnet_data_file || -z $artnet_data_file) {
	sleep 1;
}

open(my $fh, '<', $artnet_data_file) or warn $!;
$artnet_data = do { local $/; <$fh> };
$artnet_data =~ s/^([^\n]+)\n?//;
my $raw_fps = $1 || 30;
close $fh;

# Force numeric conversion and prevent division by zero
if ($raw_fps =~ /^(\d+)\/(\d+)$/) {
	$fps = $1 / $2;
} else {
	$fps = $raw_fps;
}
$fps = 30 if $fps <= 0;

print "frame rate: $fps\n";
$cross_fade_per_step = 1 / ($cross_fade_time * $fps) / 2;

while (1) {
	# Check for Redis trigger to load new data
	if ($redis->get('trigger_new_data') eq '1') {
		$redis->set('trigger_new_data', '0');
		$cross_fade_state = 'fade_out';
		
		print "fading to new data\n";
		open(my $fh, '<', $artnet_data_file) or warn $!;
		$new_artnet_data = do { local $/; <$fh> };
		$new_artnet_data =~ s/^([^\n]+)\n?//;
		my $raw_fps = $1;
		
		if (defined $raw_fps && $raw_fps =~ /^(\d+\/\d+|\d+(\.\d+)?)$/) {
			$fps = ($raw_fps =~ /^(\d+)\/(\d+)$/) ? ($1 / $2) : $raw_fps;
		}
		$fps ||= 30; # Safety default
		print "frame rate: $fps\n";
		$cross_fade_per_step = 1 / ($cross_fade_time * $fps) / 2;
		warn "[DEBUG] cross_fade_per_step updated to $cross_fade_per_step\n";
		close $fh;
	}

	foreach (split("\n", $artnet_data)) {
		next if length($_) < 2;
		@pixel_line = (/.{2}/g);
		if ($cross_fade_state eq 'fade_out' && $cross_fade_intensity > 0.0) {
			$cross_fade_intensity -= $cross_fade_per_step;
		}
		elsif ($cross_fade_state eq 'fade_out' && $cross_fade_intensity <= 0) {
			print "faded out\n";
			$cross_fade_intensity = 0.0;
			$cross_fade_state = 'off';
			if ($should_exit) {
				die "$0 quitting\n";
			}
			else {
				# switch to new data
				$artnet_data = $new_artnet_data;

				$cross_fade_state = 'fade_in';
				last;
			}
		}
		elsif ($cross_fade_state eq 'fade_in' && $cross_fade_intensity < 1.0) {
			$cross_fade_intensity += $cross_fade_per_step;
		}
		elsif ($cross_fade_state eq 'fade_in' && $cross_fade_intensity >= 1.0) {
			print "faded in\n";
			$cross_fade_intensity = 1.0;
			$cross_fade_state = 'on';
		}
		
		# respect the limits
		if ($cross_fade_intensity < 0.0) {
			$cross_fade_intensity = 0.0;
		}
		if ($cross_fade_intensity > 1.0) {
			$cross_fade_intensity = 1.0;
		}
		
		my $i = 0;
		# Force numeric values with '|| 0.0'
		$intensity = ($intensity || 0.0);
		$intensity_artnet = ($intensity_artnet || 0.0);
	
		while (($red, $green, $blue) = splice(@pixel_line, 0, 3)) {
			$artnet->set_pixel(
				pixel => $i,
				red   => $intensity_artnet * $intensity * hex($red)   * $cross_fade_intensity,
				green => $intensity_artnet * $intensity * hex($green) * $cross_fade_intensity,
				blue  => $intensity_artnet * $intensity * hex($blue)  * $cross_fade_intensity
			);
			$i++;
		}
		$artnet->send_artnet(fps => $fps);
	}
}

1;
