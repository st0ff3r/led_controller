package LedController;

use strict;
use File::Temp qw(tempfile tempdir);
use File::Copy;
use Image::Magick;
use Image::Size;
use Config::Simple;
use File::Path qw(make_path remove_tree);
use Proc::Killall;
use Redis;
use Data::Dumper;

use constant TEMP_DIR => '/led_controller/data/tmp';
use constant ARTNET_CONF => '/led_controller/artnet.conf';
use constant SLITSCAN_IMAGE_MAX_HEIGHT => 10000;
use constant REDIS_HOST => 'redis';
use constant REDIS_PORT => '6379';

$| = 1; # Force autoflush

my $config = new Config::Simple(ARTNET_CONF);

sub new {
	my $class = shift;
	my %p = @_;
	my $self = {};
	$self->{session_id} = $p{session_id};
	$self->{slitscan_image} = new Image::Magick;
	$self->{redis} = Redis->new(server => REDIS_HOST . ':' . REDIS_PORT) || warn $!;
	
	if (! -d TEMP_DIR) {
		make_path(TEMP_DIR, { mode => 0777 }) or warn "[LedController] Warning: Could not create " . TEMP_DIR . ": $!";
	}

	bless $self, $class;
	return($self);
}

sub update_progress {
	my ($self, $val) = @_;
	my $formatted = sprintf("%.1f", $val);
	
	# Update standard state for other components
	$self->{redis}->set('progress', $formatted);
	
	# Broadcast to listeners (SSE relay)
	$self->{redis}->publish('progress_channel', $formatted);
	
	# Force flush the Redis socket
	$self->{redis}->wait_all_responses();

	warn "[LedController] Progress updated to $formatted%\n";
}

sub movie_to_artnet {
	my $self = shift;
	my %p = @_;
	
	my $movie_file = $p{movie_file};
	my $artnet_data_file = $p{artnet_data_file};
	my $num_pixels = $config->param('num_pixels');

	warn "[LedController] Starting movie conversion: $movie_file\n";
	$self->update_progress(50.0);
	
	# Detect frame rate and total frames
	my $fps_cmd = "ffprobe -v error -select_streams v -of default=noprint_wrappers=1:nokey=1 -show_entries stream=r_frame_rate $movie_file";
	my $fps = `$fps_cmd`; chomp($fps);
	
	my $total_frames_cmd = "ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=nokey=1:noprint_wrappers=1 $movie_file";
	my $total_frames = `$total_frames_cmd`; chomp($total_frames);
	$total_frames ||= 1;
	
	if (!$fps) { 
		warn "[LedController] ERROR: Failed to detect FPS\n";
		$self->{redis}->set('progress', '-1'); 
		return 0; 
	}
	
	# Initialize Slitscan canvas in memory
	$self->{slitscan_image}->Set(size => "${num_pixels}x" . SLITSCAN_IMAGE_MAX_HEIGHT, depth => 8);
	$self->{slitscan_image}->ReadImage('canvas:white');

	# Execute ffmpeg pipe
	my $cmd = "ffmpeg -i $movie_file -vf scale=$num_pixels:1:flags=neighbor -f rawvideo -pix_fmt rgb24 -";
	open(my $pipe, "-|", $cmd) or die "Pipe failed: $!";

	my ($fh_out, $temp_artnet_data_file) = tempfile( DIR => TEMP_DIR, UNLINK => 0 );
	print $fh_out "$fps\n";
	
	my $row_size = $num_pixels * 3;
	my $i = 0;
	
	warn "[LedController] Starting streaming slitscan build\n";
	
	while (read($pipe, my $frame_buffer, $row_size)) {
		# ArtNet Output
		print $fh_out unpack('H*', $frame_buffer) . "\n";

		# Slitscan build in memory using SetPixel
		if ($i < SLITSCAN_IMAGE_MAX_HEIGHT) {
			my @rgb = unpack('C*', $frame_buffer);
			for (my $x = 0; $x < $num_pixels; $x++) {
				my $r = $rgb[$x * 3] / 255;
				my $g = $rgb[$x * 3 + 1] / 255;
				my $b = $rgb[$x * 3 + 2] / 255;
				$self->{slitscan_image}->SetPixel(x => $x, y => $i, color => [$r, $g, $b]);
			}
		}

		if ($i % 100 == 0) {
			warn "[LedController] Slitscan build progress: row $i\n";
		}

		# Update progress every 50 frames
		if ($i % 50 == 0) {
			my $percent = 50.0 + (($i / $total_frames) * 45.0);
			$self->update_progress($percent);
		}
		$i++;
	}
	close($pipe);
	
	# Validate pipe
	if ($? != 0) { warn "[LedController] FFmpeg pipe error exit code: $?"; return 0; }
	
	# Crop slitscan to actual height used
	$self->{slitscan_image}->Crop(geometry => "${num_pixels}x$i+0+0");
	
	warn "[LedController] Slitscan image build finished.\n";
	
	close($fh_out);
	move($temp_artnet_data_file, $artnet_data_file) || die $!;
	
	warn "[LedController] Triggering Redis update for send_artnet_data\n";
	$self->{redis}->set('trigger_new_data', '1');
	return 1;
}

sub movie_to_slitscan {
	my $self = shift;
	my %p = @_;
	
	# Defensive check
	if (!$self->{slitscan_image} || $self->{slitscan_image}->Get('width') == 0) {
		warn "[LedController] ERROR: Image object is invalid or empty. Aborting write.\n";
		return 0;
	}
	
	warn "[LedController] Starting slitscan image creation...\n";
	
	# Create temp file
	my ($fh, $temp_file) = tempfile( DIR => TEMP_DIR, CLEANUP => 1, SUFFIX => '.png');
	
	# Added log before Magick Write
	warn "[LedController] Writing slitscan image to temp: $temp_file\n";
	my $status = $self->{slitscan_image}->Write($temp_file);
	close($fh);
	
	if ($status) {
		warn "[LedController] Magick Write Error: $status\n";
		return 0;
	}
	
	# Validate file size before move
	if (-s $temp_file > 0) {
		warn "[LedController] Moving slitscan to final destination: $p{slitscan_file}\n";
		move($temp_file, $p{slitscan_file}) || die "Move failed: $!";
		$self->update_progress(100.0);
		warn "[LedController] Slitscan generation complete (100%)\n";
		sleep 2;
	} else {
		warn "[LedController] ERROR: Generated temp file is 0 bytes, aborting move.\n";
		return 0;
	}
	
	return 1;
}

sub cleanup_temp_files {
	my $self = shift;
	$self->{redis}->del('progress', 'system_locked');
}

1;
