package LedController::Progress;
use strict;
use Apache2::RequestRec;
use Apache2::RequestIO;
use Apache2::Const -compile => qw(OK);
use Redis;

sub handler {
	my $r = shift;

	my $redis_sock = $ENV{REDIS_SOCK} || die "FATAL: REDIS_SOCK environment variable is not defined!\n";

	$self->{redis} = Redis->new(
		sock => $redis_sock,
	) || die "FATAL: [$0] Could not connect to Redis socket: $!\n";

	my $subscriber = Redis->new(
		sock => $redis_sock,
	) || die "FATAL: [$0] Could not connect to Redis socket: $!\n";
	
	$r->content_type('text/event-stream');
	$r->headers_out->set('Cache-Control' => 'no-cache');
	$r->rflush();

	my $val = $redis->get('progress') || '0.0';
	
	# If a user reloads the page or re-subscribes and the value is -1.0 or ERROR,
	# override it to 0.0 so stale states never leak into brand new requests.
	if ($val eq '-1.0' || $val eq 'ERROR') { $val = '0.0'; }

	$r->print("data: $val\n\n");
	$r->rflush();

	my $job_finished = 0;

	my $sub_callback = sub {
		my ($message, $topic) = @_;
		$r->print("data: $message\n\n");
		$r->rflush();
		
		# Catch the sentinel value to flip the loop control flag
		if ($message eq '-1.0') {
			$job_finished = 1;
		}
	};

	$subscriber->subscribe('progress_channel', $sub_callback);
	
	while (!$job_finished) { 
		$subscriber->wait_for_messages(1); 
	}
	
	# Reset the value in Redis so future page uploads start fresh
	$redis->set('progress', '0.0');
	
	return Apache2::Const::OK;
}

1;
