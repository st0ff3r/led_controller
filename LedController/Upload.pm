package LedController::Upload;
use strict;
use Apache2::RequestRec;
use Apache2::Const;
use File::Temp qw(tempfile);
use Redis;
use CGI;

sub handler {
	my $r = shift;
	my $redis = Redis->new(server => '127.0.0.1:6379');

	# Check if system is already busy
	if ($redis->exists('system_locked')) {
		return Apache2::Const::FORBIDDEN;
	}

	my $q = CGI->new;
	my $fh_in = $q->upload('movie_file');
	
	if ($fh_in) {
		my ($fh_out, $temp_file) = tempfile(DIR => '/tmp', SUFFIX => '.mov', UNLINK => 0);
		
		# Set binary mode for clean file transfer
		binmode($fh_in);
		binmode($fh_out);
		
		my $total_size = $r->headers_in->get('Content-Length') || 1;
		my $bytes_read = 0;
		my $buffer;

		# Reset progress
		$redis->set('progress', 0);

		# Read in 16KB chunks to allow progress updates
		while (read($fh_in, $buffer, 16384)) {
			print $fh_out $buffer;
			$bytes_read += length($buffer);
			
			# Calculate 0-50% for upload phase
			my $percent = int(($bytes_read / $total_size) * 50);
			$redis->set('progress', $percent);
		}
		
		close $fh_out;
		
		# Add job to queue
		$redis->rpush('job_queue', $temp_file);
		
		return Apache2::Const::OK;
	}
	
	return Apache2::Const::FORBIDDEN;
}

1;
