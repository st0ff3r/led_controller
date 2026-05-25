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
	
	my $movie_file	   = $p{movie_file};
	my $artnet_data_file = $p{artnet_data_file};
	my $slitscan_file	= $p{slitscan_file};;
	my $num_pixels	   = $config->param('num_pixels');

	warn "[LedController] Starting nested conversion for: $movie_file\n";
	$self->update_progress(50.0);

	# 1. Gather metadata for progress tracking
	my $fps = `ffprobe -v error -select_streams v -of default=noprint_wrappers=1:nokey=1 -show_entries stream=r_frame_rate $movie_file`;
	chomp($fps);
	my $total_frames = `ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 $movie_file`;
	chomp($total_frames);
	$total_frames ||= 1;

	# 2. Build the complex filter graph
	# scale -> split into two branches: [raw] for ArtNet, [tile] for the image
	# 2. Build the complex filter graph
	my $filter_graph = "scale=$num_pixels:1:flags=neighbor,split[raw][tile],[tile]tile=1x${total_frames}[slitscan]";

	# 3. Construct FFmpeg command
	# We output the [raw] stream to stdout (pipe) and [slitscan] to file
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
	
	print $fh_out "$fps\n";
	
	my $row_size = $num_pixels * 3;
	my $i = 0;
	
	while (read($pipe, my $frame_buffer, $row_size)) {
		print $fh_out unpack('H*', $frame_buffer) . "\n";

		if ($i % 50 == 0) {
			$self->update_progress(50.0 + (($i / $total_frames) * 49.0));
		}
		$i++;
	}
	
	close($pipe);
	close($fh_out);
	
	$self->{redis}->set('trigger_new_data', '1');
	return 1;
}

sub cleanup_temp_files {
	my $self = shift;
	$self->{redis}->del('progress', 'system_locked');
}

1;
