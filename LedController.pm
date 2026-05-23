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
	$self->{redis} = Redis->new(server => REDIS_HOST . ':' . REDIS_PORT) || warn $!;
	bless $self, $class;
	return($self);
}

sub update_progress {
	my ($self, $val) = @_;
	$self->{redis}->set('progress', sprintf("%.1f", $val));
}

sub movie_to_artnet {
	my $self = shift;
	my %p = @_;
	
	$movie_file = $p{movie_file};
	my $artnet_data_file = $p{artnet_data_file};
	my $loop_forth_and_back = $p{loop_forth_and_back} || undef;

	$self->update_progress(50.0);
	
	my $fps_str;
	if (open(my $fh, "-|", "ffprobe", "-v", "error", "-select_streams", "v", "-of", "default=noprint_wrappers=1:nokey=1", "-show_entries", "stream=r_frame_rate", $movie_file)) {
		$fps_str = <$fh>;
		close($fh);
	}

	my $fps;
	if (defined $fps_str && $fps_str =~ /^(\d+\/\d+|\d+(\.\d+)?)$/) { $fps = $1; }
	if (!$fps) { $self->{redis}->set('progress', '-1'); return 0; }
	
	# Get duration using ffprobe for stability
	my $movie_duration = 0;
	my $duration_str = `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $movie_file`;
	chomp($duration_str);
	$movie_duration = $duration_str if $duration_str =~ /^\d+(\.\d+)?$/;
	
	$temp_dir = tempdir( CLEANUP => 0 );

	my $ffmpeg_vf = "scale=" . $config->param('num_pixels') . ":-2:flags=neighbor,crop=" . $config->param('num_pixels') . ":1:0:";
	
	# Execute ffmpeg with stderr redirected to stdout to capture progress
	open(FFMPEG, "-|", "ffmpeg", "-i", $movie_file, "-progress", "-", "-vf", $ffmpeg_vf, "-r", $fps, "$temp_dir/%08d.png");
	while (<FFMPEG>) {
		if (/out_time=(\d{2}):(\d{2}):(\d{2})(\.\d+)/) {
			my $movie_converted = $1 * 3600 + $2 * 60 + $3 + $4;
			# Safeguard against division by zero
			if ($movie_duration > 0) {
				$self->update_progress(50.0 + (($movie_converted / $movie_duration) * 25.0));
			}
		}
	}
	close(FFMPEG);
	
	opendir(DIR, $temp_dir) || die "can't opendir $temp_dir: $!";
	my @images = sort { $a cmp $b } grep { -f "$temp_dir/$_" } readdir(DIR);
	closedir DIR;

	my $slitscan_image_height = scalar(@images) > SLITSCAN_IMAGE_MAX_HEIGHT ? SLITSCAN_IMAGE_MAX_HEIGHT : scalar(@images);
	$self->{slitscan_image}->Set(size=>$config->param('num_pixels') . 'x' . $slitscan_image_height);
	$self->{slitscan_image}->ReadImage('canvas:white');

	my ($fh_out, $temp_artnet_data_file) = tempfile( CLEANUP => 0 );
	print $fh_out "$fps\n";
	
	my $i = 0;
	my $progress_inc = 25.0 / (scalar(@images) + ($loop_forth_and_back ? scalar(@images) - 2 : 0));
	foreach (@images) {
		my $p = new Image::Magick;
		$p->Read("$temp_dir/$_");
		my ($w, $h) = $p->Get('width', 'height');
		for my $x (0..$w-1) {
			my ($red, $green, $blue) = $p->GetPixel(x => $x, y => int($h / 2));
			print $fh_out sprintf("%02x%02x%02x", int($red * 255), int($green * 255), int($blue * 255));
			$self->{slitscan_image}->SetPixel(x => $x, y => $i, color => [$red, $green, $blue]) if $i < $slitscan_image_height;
		}
		print $fh_out "\n";
		$self->update_progress($self->{redis}->get('progress') + $progress_inc);
		$i++;
	}
	
	if ($loop_forth_and_back && scalar(@images) >= 3) {
		foreach (reverse @images[1..$#images-1]) {
			my $p = new Image::Magick;
			$p->Read("$temp_dir/$_");
			my ($w, $h) = $p->Get('width', 'height');
			for my $x (0..$w-1) {
				my ($red, $green, $blue) = $p->GetPixel(x => $x, y => int($h / 2));
				print $fh_out sprintf("%02x%02x%02x", int($red * 255), int($green * 255), int($blue * 255));
			}
			print $fh_out "\n";
			$self->update_progress($self->{redis}->get('progress') + $progress_inc);
		}
	}
	close($fh_out);
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
	$self->update_progress(100.0);
	sleep 2;	
}

sub cleanup_temp_files {
	my $self = shift;
	$self->{redis}->del('progress', 'system_locked');
}

1;
