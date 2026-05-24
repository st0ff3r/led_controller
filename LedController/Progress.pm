package LedController::Progress;
use strict;
use Apache2::RequestRec;
use Apache2::RequestIO;
use Apache2::Const -compile => qw(OK);
use Redis;

sub handler {
	my $r = shift;
	my $redis = Redis->new(server => 'redis:6379');
	
	$r->content_type('text/event-stream');
	$r->headers_out->set('Cache-Control' => 'no-cache');
	$r->headers_out->set('Connection' => 'keep-alive');
	$r->rflush();

	my $last_val = -1;
	
	# Wrap the streaming loop in an eval block to catch Apache write/flush drops gracefully
	eval {
		# Stream progress updates until complete
		while (1) {
			my $val = $redis->get('progress') || 0;
			
			# Only push if progress updated
			if ($val != $last_val) {
				$r->print("data: $val\n\n");
				$r->rflush(); # If client disconnected, this statement trips a fatal exception and breaks out
				$last_val = $val;
			}
			
			# Break loop when finished
			last if $val >= 100;
			
			sleep 1;
		}
		
		# Send final DONE signal
		$r->print("data: DONE\n\n");
		$r->rflush();
	};

	# --- CLEANUP STEP ---
	# This code runs no matter what: normal loop termination or an eval exception via a socket drop
	warn "[LedController::Progress] Connection dropped or job concluded. Running session lock cleanup sequence.\n";
	$redis->del('system_locked');
	$redis->del('progress');
	
	return Apache2::Const::OK;
}
1;
