package LedController;

use strict;
use File::Temp qw( tempfile tempdir );
use File::Copy;
use Image::Magick;
use Image::Size;
use Config::Simple;
use File::Path qw(remove_tree);
use Proc::Killall;
use Redis;
use Data::Dumper;

use constant ARTNET_CONF => '/led_controller/artnet.conf';
use constant SLITSCAN_IMAGE_MAX_HEIGHT => 10000;

use constant REDIS_HOST => '127.0.0.1';
use constant REDIS_PORT => '6379';

my $config = new Config::Simple(ARTNET_CONF);

my $movie_file;
my $temp_artnet_data_file;
my $temp_dir;

sub new {
	my $class = shift;
	my %p = @_;
	my $self = {};
	
	$self->{session_id} = $p{session_id};

	$self->{slitscan_image} = new Image::Magick;

	my $redis_host = REDIS_HOST;
	my $redis_port = REDIS_PORT;
	$self->{redis} = Redis->new(
		server => "$redis_host:$redis_port",
	) || warn $!;
		
	$self->{session_id} = undef;
	
	bless $self, $class;

	return($self);
}

# [DIN EKSISTERENDE movie_to_artnet KODE HER]
sub movie_to_artnet {
    # ... (din eksisterende kode) ...
}

# [DIN EKSISTERENDE movie_to_slitscan KODE HER]
sub movie_to_slitscan {
    # ... (din eksisterende kode) ...
}

sub cleanup_temp_files {
	my $self = shift;
	my $id = shift;
	
	warn "cleaning up temp files\n";
	unlink($temp_artnet_data_file);
	unlink($movie_file);
	remove_tree($temp_dir);
	
	my $redis_host = REDIS_HOST;
	my $redis_port = REDIS_PORT;
	my $redis = Redis->new(
		server => "$redis_host:$redis_port",
	) || warn $!;

	$redis->del('progress');
	$redis->del('system_locked'); # Frigiv lås
}

1;
