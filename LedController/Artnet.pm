package LedController::Artnet;

use Data::Dumper;

use constant NUM_CHANNELS_PER_PIXEL => 3;
use constant PIXEL_FORMAT => 'GRB';

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

# flush after every write
$| = 1;

sub new {
	my $class = shift;
	my %p = @_;
	my $self = {};

	# network connection
	$self->{socket} = new IO::Socket::INET (
		PeerAddr	=> $p{peer_addr} . ":6454",
		Proto		=> 'udp'
	) || die "ERROR in socket creation : $!\n";

	$self->{dmx_channels} = chr(0) x 512;
	$self->{universe} = 0;

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
	
	if ($pixel * NUM_CHANNELS_PER_PIXEL <= 512) {
		if (PIXEL_FORMAT eq 'GRB') {
			vec($self->{dmx_channels}, $pixel * NUM_CHANNELS_PER_PIXEL + 0, 8) = gamma_correction(int(0xff * $green));
			vec($self->{dmx_channels}, $pixel * NUM_CHANNELS_PER_PIXEL + 1, 8) = gamma_correction(int(0xff * $red));
			vec($self->{dmx_channels}, $pixel * NUM_CHANNELS_PER_PIXEL + 2, 8) = gamma_correction(int(0xff * $blue));
		}
	}
}

sub send_artnet {
	my ($self) = @_;

	my $packet = "Art-Net\x00\x00\x50\x00\x0e\x00\x00" . chr($self->{universe}) . "\x00" . chr(2) . chr(0) . $self->{dmx_channels};
	$self->{socket}->send($packet);
}

# private functions
sub gamma_correction {
	return $gamma_table[shift];
}

1;

__END__