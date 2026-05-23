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

sub movie_to_artnet {
	my $self = shift;
	my %p = @_;
	
	$movie_file = $p{movie_file};
	my $artnet_data_file = $p{artnet_data_file};
	my $loop_forth_and_back = $p{loop_forth_and_back} || undef;

	# movie file was uploaded
	$self->{redis}->set('progress', '50.0');	# 50% done
	my $fps_str;
	if (open(my $fh, "-|", "ffprobe", "-v", "error", "-select_streams", "v", "-of", "default=noprint_wrappers=1:nokey=1", "-show_entries", "stream=r_frame_rate", $movie_file)) {
		$fps_str = <$fh>;
		close($fh);
	}

	my $fps;
	if (defined $fps_str && $fps_str =~ /^(\d+\/\d+|\d+(\.\d+)?)$/) {
		$fps = $1;
	}
	
	if (!$fps) {
		$self->{redis}->set('progress', '-1');	# signaling an error to web client
		return 0;	
	}
	
	$temp_dir = tempdir( CLEANUP => 0 );
	my $movie_duration;
	my $movie_converted;
	my $movie_convertion_progress;

	my $ffmpeg_vf = "scale=" . $config->param('num_pixels') . ":-2:flags=neighbor,crop=" . $config->param('num_pixels') . ":1:0:";
	open(FFMPEG, "-|", "ffmpeg", "-i", $movie_file, "-progress", "-", "-vf", $ffmpeg_vf, "-r", $fps, $temp_dir . "/%08d.png");
	while (<FFMPEG>) {
		if (/Duration: (\d{2}):(\d{2}):(\d{2})(\.\d+),/) {
			$movie_duration = $1 * 60 * 60 + $2 * 60 + $3 + $4;
		}
		if (/out_time=(\d{2}):(\d{2}):(\d{2})(\.\d+)/) {
			$movie_converted = $1 * 60 * 60 + $2 * 60 + $3 + $4;
			$movie_convertion_progress = $movie_converted / $movie_duration;
			$self->{redis}->set('progress', 50.0 + ($movie_convertion_progress * 25.0));	# 50% - 75% done
		}
	}
	close(FFMPEG);
	
	opendir(DIR, $temp_dir) || die "can't opendir $temp_dir: $!";
	my @images = grep { -f "$temp_dir/$_" } readdir(DIR);
	closedir DIR;

	my $slitscan_image_height = scalar(@images);
	if ($slitscan_image_height > SLITSCAN_IMAGE_MAX_HEIGHT) {	
		$slitscan_image_height = SLITSCAN_IMAGE_MAX_HEIGHT;
	}
	$self->{slitscan_image}->Set(size=>$config->param('num_pixels') . 'x' . $slitscan_image_height);
	$self->{slitscan_image}->ReadImage('canvas:white');

	my ($image_size_x, $image_size_y);
	my $x;
	my $fh;
	($fh, $temp_artnet_data_file) = tempfile( CLEANUP => 0 );
	my ($red, $green, $blue);

	print $fh "$fps\n";
	@images = sort { $a cmp $b } @images;
	my $i = 0;
	my $progress_inc = 25.0 / (@images + ($loop_forth_and_back ? @images - 2 : 0));
	foreach (@images) {
		($image_size_x, $image_size_y) = imgsize("$temp_dir/$_");
	
		my $p = new Image::Magick;
		$p->Read("$temp_dir/$_");
		for $x (0..$image_size_x) {
			($red, $green, $blue) = $p->GetPixel( 'x' => $x, 'y' => int($image_size_y / 2) );
			print $fh sprintf("%02x", int($red * 255)) . sprintf("%02x", int($green * 255)) . sprintf("%02x", int($blue * 255));
			if ($i <= $slitscan_image_height) {
				$self->{slitscan_image}->SetPixel(x => $x, y => $i, color=> [$red, $green, $blue]);
			}
		}
		print $fh "\n";
		$i++;
		my $progress = $self->{redis}->get('progress');
		if ($progress + $progress_inc < 100.0) {	
			$self->{redis}->set('progress', ($progress + $progress_inc));
		}
	}
	if ($loop_forth_and_back && @images >= 3) {
		@images = sort { $b cmp $a } @images;	
		shift(@images);	
		pop(@images);	
		foreach (@images) {
			($image_size_x, $image_size_y) = imgsize("$temp_dir/$_");
		
			my $p = new Image::Magick;
			$p->Read("$temp_dir/$_");
			for $x (0..$image_size_x) {
				($red, $green, $blue) = $p->GetPixel( 'x' => $x, 'y' => int($image_size_y / 2) );
				print $fh sprintf("%02x", int($red * 255)) . sprintf("%02x", int($green * 255)) . sprintf("%02x", int($blue * 255));
			}
			print $fh "\n";
			my $progress = $self->{redis}->get('progress');
			if ($progress + $progress_inc < 100.0) {	
				$self->{redis}->set('progress', ($progress + $progress_inc));
			}
		}
	}
	close($fh);
	move($temp_artnet_data_file, $artnet_data_file) || die $!;
	remove_tree($temp_dir);

	killall('USR2', 'send_artnet_data');
	
	return 1;
}

sub movie_to_slitscan {
	my $self = shift;
	my %p = @_;

	my ($fh, $temp_file) = tempfile( CLEANUP => 0, SUFFIX => '.png');
	$self->{slitscan_image}->Write($temp_file);
	close($fh);
	move($temp_file, $p{slitscan_file}) || die $!;
	$self->{redis}->set('progress', '100.0');
	sleep 2;	
}

sub set_session_id {
	my $self = shift;
	$self->{session_id} = shift;
	
	if ($self->{redis}->keys('progress')) {
		return 0;
	}
	else {
		$self->{redis}->set('progress', '0.0');
		return 1;
	}
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
	$redis->del('system_locked');
}

1;
