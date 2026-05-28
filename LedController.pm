package LedController;

use strict;
use Config::Simple;
use File::Path qw(make_path);
use Redis;
use File::Copy;

use constant ARTNET_CONF => '/led_controller/artnet.conf';

$| = 1; # Force autoflush

my $config = new Config::Simple(ARTNET_CONF);

sub new {
	my $class = shift;
	my %p = @_;
	my $self = {};
	my $redis_sock = $ENV{REDIS_SOCK} || die "FATAL: REDIS_SOCK environment variable is not defined!\n";
	$self->{redis} = Redis->new(
		sock => $redis_sock,
	) || die "FATAL: [$0] Could not connect to Redis socket: $!\n";

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
	
	my $movie_file          = $p{movie_file};
	my $artnet_data_file    = $p{artnet_data_file};
	my $slitscan_file       = $p{slitscan_file};
	my $loop_forth_and_back = $p{loop_forth_and_back} || 0;
	my $num_pixels          = $config->param('num_pixels');

	warn "[LedController] Starting optimized conversion for: $movie_file\n";
	$self->update_progress(50.0);

	# 1. Gather metadata for progress tracking
	my $fps = `ffprobe -v error -select_streams v -of default=noprint_wrappers=1:nokey=1 -show_entries stream=r_frame_rate $movie_file`;
	chomp($fps);
	my $total_frames = `ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 $movie_file`;
	chomp($total_frames);
	$total_frames ||= 1;

	# 2. Build the complex filter graph
	# scale -> split into two branches: [raw] for ArtNet, [tile] for the image
	my $filter_graph = "scale=$num_pixels:1:flags=neighbor,split[raw][tile],[tile]tile=1x${total_frames}[slitscan]";

	# 3. Construct FFmpeg command
	my @cmd = (
		'ffmpeg',
		'-i', $movie_file,
		'-filter_complex', $filter_graph,
		# ArtNet branch
		'-map', '[raw]',
		'-f', 'rawvideo',
		'-pix_fmt', 'rgb24', '-',
		# Slitscan branch
		'-map', '[slitscan]',
		'-update', '1',
		$slitscan_file,
		'-y'
	);

	# 4. Execute
	open(my $pipe, "-|", @cmd) or die "FFmpeg execution failed: $!";
	open(my $fh_out, '>', $artnet_data_file) or die "Cannot write to $artnet_data_file: $!";
	
	# Write the detected frame rate header
	print $fh_out "$fps\n";
	
	my $row_size = $num_pixels * 3;
	my $i = 0;
	my @buffered_hex_frames = ();
	
	# Stream frames directly out of the pipeline
	while (read($pipe, my $frame_buffer, $row_size)) {
		my $hex_str = unpack('H*', $frame_buffer);
		print $fh_out "$hex_str\n";

		# If looping is enabled, cache the hex lines in memory for the return trip
		if ($loop_forth_and_back) {
			push @buffered_hex_frames, $hex_str;
		}

		if ($i % 50 == 0) {
			# Progress spans from 50% to roughly 99%
			$self->update_progress(50.0 + (($i / $total_frames) * 49.0));
		}
		$i++;
	}
	close($pipe);

	# Check execution exit status flag of the pipeline close
	if ($? != 0) {
		warn "[LedController] FFmpeg pipeline encountered execution errors ($?)\n";
		close($fh_out);
		return 0;
	}

	# 5. Append the frames in reverse order if loop_forth_and_back is requested
	if ($loop_forth_and_back && scalar(@buffered_hex_frames) >= 3) {
		warn "[LedController] Appending reverse loop frames...\n";
		
		# Slit-scan animations omit the first and last frame on the bounce
		# to ensure continuous visual playback without pause stuttering.
		my $total_loop_steps = $#buffered_hex_frames - 1;
		my $step = 0;

		for (my $j = $#buffered_hex_frames - 1; $j >= 1; $j--) {
			print $fh_out "$buffered_hex_frames[$j]\n";

			if ($step % 50 == 0) {
				$self->update_progress(75.0 + (($step / $total_loop_steps) * 24.0));
			}
			$step++;
		}
	}
	
	close($fh_out);
	
	$self->update_progress(100.0);
	$self->{redis}->set('trigger_new_data', '1');
	return 1;
}

sub cleanup_temp_files {
	my $self = shift;
	$self->{redis}->del('progress', 'system_locked');
}

1;
