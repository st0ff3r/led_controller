package LedController::Artnet;

use strict;
use Time::HiRes qw(usleep gettimeofday tv_interval);
use POSIX qw( ceil );
use Redis;
use Data::Dumper;
use Data::HexDump;

use constant REDIS_QUEUE_1_NAME => 'artnet_1';
use constant REDIS_QUEUE_2_NAME => 'artnet_2';

use constant BUFFER_TIME => 1;

my @gamma_table = (
	0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
	0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,
	1,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  2,  2,
	2,  3,  3,  3,  3,  3,  3,  3,  4,  4,  4,  4,  4,  5,  5,  5,
	5,  6,  6,  6,  6,  7,  7,  7,  7,  8,  8,  8,  9,  9,  9, 10,
	10, 10, 11, 11, 11, 12, 12, 13, 13, 13, 14, 14, 15, 15, 16, 16,
	17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 24, 24, 25,
	25, 26, 27, 27, 28, 29, 29, 30, 31, 32, 32, 33, 34, 35, 35, 36,
	37, 38, 39, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 50,
	51, 52, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 66, 67, 68,
	69, 70, 72, 73, 74, 75, 77, 78, 79, 81, 82, 83, 85, 86, 87, 89,
	90, 92, 93, 95, 96, 98, 99,101,102,104,105,107,109,110,112,114,
	115,117,119,120,122,124,126,127,129,131,133,135,137,138,140,142,
	144,146,148,150,152,154,156,158,160,162,164,167,169,171,173,175,
	177,180,182,184,186,189,191,193,196,198,200,203,205,208,210,213,
	215,218,220,223,225,228,231,233,236,239,241,244,247,249,252,255
);

sub new {
	my $class = shift;
	my %p = @_;
	my $self = {};

	$self->{num_channels_per_pixel} = $p{num_channels_per_pixel};
	$self->{pixel_format} = $p{pixel_format};
	$self->{num_pixels} = $p{num_pixels};
	$self->{universes_per_port} = $p{universes_per_port};
	$self->{is_mirrored_on_first_port} = $p{is_mirrored_on_first_port};
	$self->{is_mirrored_on_second_port} = $p{is_mirrored_on_second_port};

	my $redis_sock = $ENV{REDIS_SOCK} || die "FATAL: REDIS_SOCK environment variable is not defined!\n";
	$self->{redis} = Redis->new(
		sock => $redis_sock,
	) || die "FATAL: [$0] Could not connect to Redis socket: $!\n";

	# init all channels to 0
	$self->{num_universes} = ceil($self->{num_pixels} * $self->{num_channels_per_pixel} / 512);
	# on first port
	for (1..$self->{num_universes}) {
		$self->{dmx_channels}[$_ - 1] = chr(0) x 512;
	}
	# on second port
	for (1..$self->{num_universes}) {
		$self->{dmx_channels_mirrored}[$_ - 1] = chr(0) x 512;
	}
	
	# calculate channel padding
	$self->{num_channels_not_used} = ($self->{num_universes} * 512) - ($self->{num_channels_per_pixel} * $self->{num_pixels});
	
	bless $self, $class;

	return($self);
}

sub set_pixel {
	my $self = shift;
	my %p = @_;
	
	my $pixel = $p{pixel};
	my $red = $p{red};
	my $green = $p{green};
	my $blue = $p{blue};
	my $white = 0;
		
	# do gamma correction and color correction
	$red = gamma_correction($red) * 1.0;
	$green = gamma_correction($green) * 0.63;
	$blue = gamma_correction($blue) * 0.94;
	
	if ($self->{num_channels_per_pixel} == 4) {
		# convert from rgb to rgbw
		@_ = sort {$a <=> $b} ($red, $green, $blue);
		$white = $_[0];
		$red -= $white;
		$green -= $white;
		$blue -= $white;
	}
	
	my $channel = ($pixel * $self->{num_channels_per_pixel}) % 512;
	my $universe = int($pixel * $self->{num_channels_per_pixel} / 512);

	my $channel_mirrored = (($self->{num_pixels} - $pixel) * $self->{num_channels_per_pixel}) % 512;
	my $universe_mirrored = int(($self->{num_pixels} - $pixel) * $self->{num_channels_per_pixel} / 512);

	if ($self->{pixel_format} eq 'GRB') {
		vec($self->{dmx_channels}[$universe], $channel + 0, 8) = $green;
		vec($self->{dmx_channels}[$universe], $channel + 1, 8) = $red;
		vec($self->{dmx_channels}[$universe], $channel + 2, 8) = $blue;

		vec($self->{dmx_channels_mirrored}[$universe_mirrored], $channel_mirrored + 0, 8) = $green;
		vec($self->{dmx_channels_mirrored}[$universe_mirrored], $channel_mirrored + 1, 8) = $red;
		vec($self->{dmx_channels_mirrored}[$universe_mirrored], $channel_mirrored + 2, 8) = $blue;
	}
	elsif ($self->{pixel_format} eq 'GRBW') {
		vec($self->{dmx_channels}[$universe], $channel + 0, 8) = $green;
		vec($self->{dmx_channels}[$universe], $channel + 1, 8) = $red;
		vec($self->{dmx_channels}[$universe], $channel + 2, 8) = $blue;
		vec($self->{dmx_channels}[$universe], $channel + 3, 8) = $white;

		vec($self->{dmx_channels_mirrored}[$universe_mirrored], $channel_mirrored + 0, 8) = $green;
		vec($self->{dmx_channels_mirrored}[$universe_mirrored], $channel_mirrored + 1, 8) = $red;
		vec($self->{dmx_channels_mirrored}[$universe_mirrored], $channel_mirrored + 2, 8) = $blue;
		vec($self->{dmx_channels_mirrored}[$universe_mirrored], $channel_mirrored + 3, 8) = $white;
	}
}

sub send_artnet {
	my $self = shift;
	my %p = @_;

	my $packet;
	my @frame_packets;
	
	# send mirrored data to first port
	if ($self->{is_mirrored_on_first_port}) {
		@frame_packets = ();
		for (1..$self->{num_universes}) {
			$packet = "Art-Net\x00\x00\x50\x00\x0e\x00\x00" . chr($_ - 1) . "\x00" . chr(2) . chr(0) . $self->{dmx_channels_mirrored}[$_ - 1];
			push @frame_packets, $packet;
		}
		# Flatten the array of packets into a single raw binary string
		$self->add_artnet_to_queue(queue => REDIS_QUEUE_1_NAME, artnet => join('', @frame_packets), fps => $p{fps});
	}
	else {
		# not mirrored on first port
		@frame_packets = ();
		for (1..$self->{num_universes}) {
			$packet = "Art-Net\x00\x00\x50\x00\x0e\x00\x00" . chr($_ - 1) . "\x00" . chr(2) . chr(0) . $self->{dmx_channels}[$_ - 1];
			push @frame_packets, $packet;
		}
		# Flatten the array of packets into a single raw binary string
		$self->add_artnet_to_queue(queue => REDIS_QUEUE_1_NAME, artnet => join('', @frame_packets), fps => $p{fps});	
	}

	# send mirrored data to other port
	if ($self->{is_mirrored_on_second_port}) {
		@frame_packets = ();
		for (1..$self->{num_universes}) {
			$packet = "Art-Net\x00\x00\x50\x00\x0e\x00\x00" . chr($_ - 1 + $self->{universes_per_port}) . "\x00" . chr(2) . chr(0) . $self->{dmx_channels_mirrored}[$_ - 1];
			push @frame_packets, $packet;
		}
		# Flatten the array of packets into a single raw binary string
		$self->add_artnet_to_queue(queue => REDIS_QUEUE_2_NAME, artnet => join('', @frame_packets), fps => $p{fps});
	}
	else {
		# not mirrored on second port
		@frame_packets = ();
		for (1..$self->{num_universes}) {
			$packet = "Art-Net\x00\x00\x50\x00\x0e\x00\x00" . chr($_ - 1 + $self->{universes_per_port}) . "\x00" . chr(2) . chr(0) . $self->{dmx_channels}[$_ - 1];
			push @frame_packets, $packet;
		}
		# Flatten the array of packets into a single raw binary string
		$self->add_artnet_to_queue(queue => REDIS_QUEUE_2_NAME, artnet => join('', @frame_packets), fps => $p{fps});
	}
	
	# wait for buffer to be emptied using lightweight LLEN against your constant layout
	while ($self->{redis}->llen(REDIS_QUEUE_1_NAME . ':queue') > (BUFFER_TIME * $p{fps})) {
		usleep 1000_000 * BUFFER_TIME / 2;
	}
}

# private functions
sub gamma_correction {
	return $gamma_table[shift];
}

sub add_artnet_to_queue {
	my $self = shift;
	my %p = @_;

	# Automatically expands your constant ('artnet_1') to match the receiver key ('artnet_1:queue')
	my $queue_base = $p{queue} . ':queue';

	# Create the next id
	my $id = $self->{redis}->incr(join(':', $p{queue}, 'id'));
	my $job_id = join(':', $p{queue}, $id);

	my %data = (topic => 'artnet', message => $p{artnet});

	# Set the data first
	$self->{redis}->hmset($job_id, %data);

	# Then add the job to the queue
	$self->{redis}->rpush($queue_base, $job_id);
	
	# Only update if the value has changed
	my $current_fps = $self->{redis}->get('fps');
	if (!defined $current_fps || $current_fps != $p{fps}) {
		$self->{redis}->set('fps', $p{fps});
	}
}

1;
