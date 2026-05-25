package LedController;

use strict;
use Config::Simple;
use File::Path qw(make_path);
use Redis;
use File::Copy;

use constant ARTNET_CONF => '/led_controller/artnet.conf';
use constant REDIS_HOST => 'redis';
use constant REDIS_PORT => '6379';

$| = 1; # Force autoflush

my $config = new Config::Simple(ARTNET_CONF);

sub new {
	my $class = shift;
	my %p = @_;
	my $self = {};
	$self->{redis} = Redis->new(server => REDIS_HOST . ':' . REDIS_PORT) || warn $!;
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

	# Extract FPS to write as the first line of the file
	my $fps = `ffprobe -v error -select_streams v -of default=noprint_wrappers=1:nokey=1 -show_entries stream=r_frame_rate $movie_file`;
	chomp($fps);
	
	my $total_frames = `ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=nokey=1:noprint_wrappers=1 $movie_file`;
	chomp($total_frames);
	$total_frames ||= 1;

	# Pipeline: ffmpeg outputs raw RGB data to Perl
	my $cmd = "ffmpeg -i $movie_file -vf scale=$num_pixels:1:flags=neighbor -f rawvideo -pix_fmt rgb24 -";
	open(my $pipe, "-|", $cmd) or die "Pipe failed: $!";
	open(my $fh_out, '>', $artnet_data_file) or die "Cannot write to $artnet_data_file: $!";
	
	# Write FPS as the first line of the data file
	print $fh_out "$fps\n";
	
	my $row_size = $num_pixels * 3;
	my $i = 0;
	
	while (read($pipe, my $frame_buffer, $row_size)) {
		# ArtNet Output
		print $fh_out unpack('H*', $frame_buffer) . "\n";

		if ($i % 50 == 0) {
			$self->update_progress(50.0 + (($i / $total_frames) * 45.0));
		}
		$i++;
	}
	close($pipe);
	close($fh_out);
	
	$self->{redis}->set('trigger_new_data', '1');
	return 1;
}

sub movie_to_slitscan {
	my $self = shift;
	my %p = @_;
	my $num_pixels = $config->param('num_pixels');
	
	# 1. Get the actual frame count from the file
	my $frame_count = `/usr/bin/ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=nokey=1:noprint_wrappers=1 $p{movie_file}`;
	chomp($frame_count);
	$frame_count ||= 717; # Fallback

	warn "[LedController] Generating slitscan, frames detected: $frame_count\n";
	
	# 2. Use tile to stack, then crop the output to the exact frame count
	# This ensures the image is exactly 100 x 717 pixels
	my $filter = "scale=$num_pixels:1:flags=neighbor,tile=1x$frame_count";
	
	my @cmd = (
		'/usr/bin/ffmpeg', 
		'-i', $p{movie_file}, 
		'-vf', $filter, 
		$p{slitscan_file}, 
		'-y'
	);
	
	my $exit_code = system(@cmd);
	
	if ($exit_code == 0) {
		$self->update_progress(100.0);
		return 1;
	} else {
		warn "[LedController] Slitscan failed with code $exit_code\n";
		return 0;
	}
}

sub cleanup_temp_files {
	my $self = shift;
	$self->{redis}->del('progress', 'system_locked');
}

1;
