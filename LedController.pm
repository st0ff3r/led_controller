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
	my $formatted = sprintf("%.1f", $val);
	$self->{redis}->set('progress', $formatted);

	# Log progress to Docker output
	warn "[LedController] Progress updated to $formatted%\n";
}

sub movie_to_artnet {
	my $self = shift;
	my %p = @_;
	
	$movie_file = $p{movie_file};
	my $artnet_data_file = $p{artnet_data_file};
	my $loop_forth_and_back = $p{loop_forth_and_back} || undef;

	warn "[LedController] Starting movie conversion: $movie_file\n";
	$self->update_progress(50.0);
	
	# Detect frame rate
	my $fps_str;
	if (open(my $fh, "-|", "ffprobe", "-v", "error", "-select_streams", "v", "-of", "default=noprint_wrappers=1:nokey=1", "-show_entries", "stream=r_frame_rate", $movie_file)) {
		$fps_str = <$fh>;
		close($fh);
	}

	my $fps;
	if (defined $fps_str && $fps_str =~ /^(\d+\/\d+|\d+(\.\d+)?)$/) { $fps = $1; }
	if (!$fps) { 
		warn "[LedController] ERROR: Failed to detect FPS\n";
		$self->{redis}->set('progress', '-1'); 
		return 0; 
	}
	
	# Get duration for progress calculation
	my $movie_duration = 0;
	my $duration_str = `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $movie_file`;
	chomp($duration_str);
	$movie_duration = $duration_str if $duration_str =~ /^\d+(\.\d+)?$/;
	
	$temp_dir = tempdir( CLEANUP => 0 );
	warn "[LedController] Temp dir created: $temp_dir\n";

	my $ffmpeg_vf = "scale=" . $config->param('num_pixels') . ":-2:flags=neighbor,crop=" . $config->param('num_pixels') . ":1:0:";
	
	# Execute ffmpeg extraction
	open(FFMPEG, "-|", "ffmpeg", "-i", $movie_file, "-progress", "-", "-vf", $ffmpeg_vf, "-r", $fps, "$temp_dir/%08d.png");
	while (<FFMPEG>) {
		if (/out_time=(\d{2}):(\d{2}):(\d{2})(\.\d+)/) {
			my $movie_converted = $1 * 3600 + $2 * 60 + $3 + $4;
			if ($movie_duration > 0) {
				$self->update_progress(50.0 + (($movie_converted / $movie_duration) * 25.0));
			}
		}
	}
	close(FFMPEG);
	
	opendir(DIR, $temp_dir) || die "can't opendir $temp_dir: $!";
	my @images = sort { $a cmp $b } grep { -f "$temp_dir/$_" } readdir(DIR);
	closedir DIR;
	warn "[LedController] Extracted " . scalar(@images) . " frames\n";

	$self->update_progress(75.0);
	
	my $slitscan_image_height = scalar(@images) > SLITSCAN_IMAGE_MAX_HEIGHT ? SLITSCAN_IMAGE_MAX_HEIGHT : scalar(@images);
	$self->{slitscan_image}->Set(size=>$config->param('num_pixels') . 'x' . $slitscan_image_height);
	$self->{slitscan_image}->ReadImage('canvas:white');

	my ($fh_out, $temp_artnet_data_file) = tempfile( CLEANUP => 0 );
	print $fh_out "$fps\n";
	
	my $total_frames = scalar(@images);
	my $total_steps = $total_frames + ($loop_forth_and_back ? $total_frames - 2 : 0);
	my $update_threshold = int($total_steps / 50) || 1;
	my $step_counter = 0;
	my $progress_inc = $total_steps > 0 ? (25.0 / $total_steps) : 0;
	
	warn "[LedController] Starting slitscan image build (height: $slitscan_image_height)\n";
	
	my $i = 0;
	# Process frames to ArtNet
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
		
		if ($i % 100 == 0) {
			warn "[LedController] Slitscan build progress: frame $i/$total_frames\n";
		}
		
		if ($step_counter % $update_threshold == 0) {
			$self->update_progress(75.0 + ($step_counter * $progress_inc));
		}
		$step_counter++;
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
			
			if ($step_counter % $update_threshold == 0) {
				$self->update_progress(75.0 + ($step_counter * $progress_inc));
			}
			$step_counter++;
		}
	}
	warn "[LedController] Slitscan image build finished.\n";
	
	close($fh_out);
	move($temp_artnet_data_file, $artnet_data_file) || die $!;
	remove_tree($temp_dir);
	
	warn "[LedController] Triggering USR2 signal for send_artnet_data\n";
	killall('USR2', 'send_artnet_data');
	return 1;
}

sub movie_to_slitscan {
	my $self = shift;
	my %p = @_;
	
	warn "[LedController] Starting slitscan image creation...\n";
	
	# Create temp file
	my ($fh, $temp_file) = tempfile( CLEANUP => 0, SUFFIX => '.png');
	
	# Added log before Magick Write
	warn "[LedController] Writing slitscan image to temp: $temp_file\n";
	$self->{slitscan_image}->Write($temp_file);
	close($fh);
	
	# Move to final destination
	warn "[LedController] Moving slitscan to final destination: $p{slitscan_file}\n";
	move($temp_file, $p{slitscan_file}) || die "Move failed: $!";
	
	# Clean up temp file immediately after move
	unlink $temp_file if -e $temp_file;
	
	$self->update_progress(100.0);
	warn "[LedController] Slitscan generation complete (100%)\n";
	
	sleep 2;	
}

sub cleanup_temp_files {
	my $self = shift;
	$self->{redis}->del('progress', 'system_locked');
}

1;
