package LedController::Progress;
use strict;
use Apache2::RequestRec;
use Apache2::RequestIO;
use Apache2::Const -compile => qw(OK);
use Redis;

sub handler {
	my $r = shift;
	# 1. Connection for getting current state
	my $redis = Redis->new(server => 'redis:6379');
	# 2. Connection dedicated to Subscribing
	my $subscriber = Redis->new(server => 'redis:6379');
	
	$r->content_type('text/event-stream');
	$r->headers_out->set('Cache-Control' => 'no-cache');
	$r->rflush();

	# Initial progress: This handles the page reload requirement.
	# The moment the browser connects, it gets the latest status from Redis.
	my $val = $redis->get('progress') || '0.0';
	$r->print("data: $val\n\n");
	$r->rflush();

	# Callback to relay messages
	my $sub_callback = sub {
		my ($message, $topic) = @_;
		$r->print("data: $message\n\n");
		$r->rflush();
		
		# We no longer die here or delete the key if we want to support 
		# persistent status check. If you want the stream to close 
		# upon completion, uncomment the die below:
		# die "DONE" if $message eq '100.0' || $message eq 'DONE';
	};

	eval {
		$subscriber->subscribe('progress_channel', $sub_callback);
		# Block until subscription receives data
		while (1) { $subscriber->wait_for_messages(10); }
	};
	
	# REMOVED: $redis->del('progress'); 
	# Do not delete the key, so reloads can see the final '100.0' or 'Ready' state.
	
	return Apache2::Const::OK;
}
1;
