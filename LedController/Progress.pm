package LedController::Progress;

use strict;
use Apache2::RequestRec;
use Apache2::RequestIO;
use Apache2::Const;
use Redis;
use CGI::Cookie ();

use constant REDIS_HOST => '127.0.0.1';
use constant REDIS_PORT => '6379';

sub handler {
    my $r = shift;
    
    my $redis = Redis->new(server => REDIS_HOST . ':' . REDIS_PORT);
        
    $r->content_type('text/event-stream');
    $r->headers_out->add('Cache-Control' => 'no-cache');
    $r->headers_out->add('Connection' => 'keep-alive');
    $r->rflush;
    
    my $last_progress = -1;
    
    while (1) {
        my $progress = $redis->get('progress');
        
        # If no progress key exists, the worker is idle
        if (!defined $progress) {
            print "data: IDLE\n\n";
            last;
        }

        if ($progress ne $last_progress) {
            print "data: $progress\n\n";
            $r->rflush;
            $last_progress = $progress;
        }

        # Exit loop if job is finished
        if ($progress eq '100') {
            last;
        }

        select(undef, undef, undef, 0.5); # Sleep 0.5s to reduce CPU load
    }
    
    return Apache2::Const::OK;
}

1;
