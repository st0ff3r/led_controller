#! /usr/bin/perl -w

use Time::HiRes qw(usleep gettimeofday tv_interval);
use Config::Simple;
use IPC::ShareLite;
use Data::Dumper;

use lib qw ( ./ );
use LedController::Artnet;

use constant ARTNET_CONF => '/led_controller/artnet.conf';

my $config = new Config::Simple(ARTNET_CONF);
my $artnet_data_file = $ARGV[0] || "data/artnet.data";
my $artnet_data = '';
my $new_artnet_data = '';

my $intensity = 0.0;
my $intensity_artnet = 0.0;
my $cross_fade_intensity = 0.0;
my $cross_fade_state = 'fade_in';
my $fps ;

my $cross_fade_time = $config->param('cross_fade_time') || 2;
my $cross_fade_per_step;

#sub print_status {
#	while (1) {
#		print("intensity: $intensity\n");
#		print("intensity_artnet: $intensity_artnet\n");
#		print("cross_fade_intensity: $cross_fade_intensity\n");
#		print("cross_fade_state: $cross_fade_state\n");
#		print("fps: $fps\n\n");
#		usleep(1000_000);
#	}
#}
#my $thread = threads->create(\&print_status);

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

$SIG{USR2} = sub {
	$cross_fade_state = 'fade_out';
	
	print "fading to new data\n";
	open(FH, '<', $artnet_data_file) or warn $!;
	$new_artnet_data = do { local $/; <FH> };	# read all data into memory
	$new_artnet_data =~ s/^(.*)//;
	$fps = $1;
	print "frame rate: $fps\n";
	$cross_fade_per_step = 1 / ($cross_fade_time * $fps) / 2;
	close FH;
};

my $should_exit = 0;
$SIG{TERM} = sub { print "$0 received SIGTERM\n"; $cross_fade_state = 'fade_out'; $should_exit = 1 };
$SIG{KILL} = sub { print "$0 received SIGKILL\n"; $cross_fade_state = 'fade_out'; $should_exit = 1 };

my @pixel_line;
my ($red, $green, $blue);

# Wait until the data file exists and is not empty
print "Waiting for artnet data file: $artnet_data_file\n";
while (!-s $artnet_data_file) {
	sleep 1;
}
open(FH, '<', $artnet_data_file) or warn $!;
$artnet_data = do { local $/; <FH> };	# read all data into memory
$artnet_data =~ s/^(.*)//;

$fps = $1;
# Force numeric conversion
if ($raw_fps =~ /^(\d+)\/(\d+)$/) {
	$fps = $1 / $2;
} else {
	$fps = $raw_fps;
}
print "frame rate: $fps\n";

$cross_fade_per_step = 1 / ($cross_fade_time * $fps) / 2;
close FH;
while (1) {
	foreach (split("\n", $artnet_data)) {
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
		while (($red, $green, $blue) = splice(@pixel_line, 0, 3)) {
			$artnet->set_pixel(
				pixel => $i,
				red => $intensity_artnet * $intensity * hex($red) * $cross_fade_intensity,
				green => $intensity_artnet * $intensity * hex($green) * $cross_fade_intensity,
				blue => $intensity_artnet * $intensity * hex($blue) * $cross_fade_intensity
			);
			$i++;
		}
		$artnet->send_artnet(fps => $fps);
	}
}

END {

}

1;

__END__
