package LedController::Progress;

use strict;
use IPC::ShareLite;
use Apache2::RequestRec;
use Apache2::RequestIO;
use Apache2::Const;
use CGI;
use CGI::Cookie ();
use Data::Dumper;

use constant REDIS_HOST => '127.0.0.1';
use constant REDIS_PORT => '6379';

$SIG{PIPE} = sub {
	warn "connection aborted\n";
};

sub handler {
	my $r = shift;
	
	my $redis_host = REDIS_HOST;
	my $redis_port = REDIS_PORT;
	my $redis = Redis->new(
		server => "$redis_host:$redis_port",
	) || warn $!;
		
	my %cookies = ();
	my $session_id = '';
	if (%cookies = CGI::Cookie->fetch) {
		# cookie received
		$session_id = $cookies{'session_id'}->value;
	
		# send it again
		my $cookie = CGI::Cookie->new(-name  => 'session_id', -value => $session_id);
		$r->err_headers_out->add('Set-Cookie' => $cookie);
	}
	
	$r->err_headers_out->add('Content-type' => 'text/event-stream');
	$r->err_headers_out->add('Cache-Control' => 'no-cache');
	$r->err_headers_out->add('Connection' => 'keep-alive');
	
	my $progress;
	my $last_progress = undef;
	while (1) {
		$progress = int($redis->get('progress'));
		if ($progress == -1) {
			print("data: ERROR\n\n");
#			$redis->del('progress');
			exit;
		}
		elsif ($progress == 100) {
			print("data: 100\n\n");			
			print("data: DONE\n\n");
#			$redis->del('progress');
			exit;
		}
		else {
			if ($progress ne $last_progress) {
				print("data: " . $progress . "\n\n");
			}
		}
		$r->rflush;
		$last_progress = $progress;
	}
}

1;

__END__
