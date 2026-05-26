package LedController::Upload;
use strict;
use Apache2::RequestRec;
use Apache2::Const -compile => qw(OK FORBIDDEN SERVER_ERROR HTTP_REQUEST_ENTITY_TOO_LARGE);
use File::Copy;
use File::Temp qw(tempfile);
use Redis;
use CGI;

use constant TARGET_TMP_DIR => '/led_controller/data/tmp';

sub handler {
	my $r = shift;
	my $redis = Redis->new(server => 'redis:6379');

	# 1. Handle HEAD requests: Always return OK so the pre-flight check passes
	if ($r->method eq 'HEAD') {
		return Apache2::Const::OK;
	}

	# 2. Check if system is busy: If locked, return FORBIDDEN for everything else (POST)
	if ($redis->exists('system_locked')) {
		return Apache2::Const::FORBIDDEN;
	}

	# Tell CGI to process input variables normally using its internal handler
	my $q = CGI->new;
	
	# Fetch the dynamic filehandle reference matching the HTML file payload input name
	my $fh_in = $q->upload('movie_file');
	
	if ($fh_in) {
		# Limit file size to 500MB (524,288,000 bytes)
		my $max_size = 500 * 1024 * 1024;
		my $file_size = $q->uploadInfo($fh_in)->{'Content-length'};
		
		if ($file_size > $max_size) {
			$r->log_error("[UploadHandler] File exceeds 500MB limit: $file_size bytes");
			return Apache2::Const::HTTP_REQUEST_ENTITY_TOO_LARGE;
		}

		# CGI automatically dumps the pristine video payload to its own hidden local tmp tracking asset
		my $cgi_tmp_file = $q->tmpFileName($fh_in);
		
		# Generate a clean, unique file path directly using File::Temp's native syntax safely
		my ($fh_temp, $filename) = tempfile(DIR => TARGET_TMP_DIR, SUFFIX => '.mov', UNLINK => 0);
		close($fh_temp); # Close the handle immediately so we can overwrite it via move()
		
		# Move the clean video file out of the unmapped system storage straight to the volume sync deck
		if (move($cgi_tmp_file, $filename)) {
			# Set standard permissions so worker group access remains uninhibited
			chmod(0666, $filename);
			
			# FORCE CLEAN SLATE: Erase any historical error states before queueing
			$redis->set('progress', '0.0');
			$redis->publish('progress_channel', '0.0');
			
			# Push the absolute shared volume path down to the worker thread loop
			$redis->rpush('job_queue', $filename);
			return Apache2::Const::OK;
		} else {
			$r->log_error("[UploadHandler] Failed to move file from $cgi_tmp_file to $filename: $!");
			return Apache2::Const::SERVER_ERROR;
		}
	}
	
	return Apache2::Const::FORBIDDEN;
}

1;
