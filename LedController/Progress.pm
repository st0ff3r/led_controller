package LedController::Progress;
use strict;
use Apache2::RequestRec;
use Apache2::RequestIO;
use Apache2::Const;
use Redis;

sub handler {
    my $r = shift;
    my $redis = Redis->new(server => '127.0.0.1:6379');
    
    $r->content_type('text/event-stream');
    $r->headers_out->add('Cache-Control' => 'no-cache');
    $r->headers_out->add('Connection' => 'keep-alive');
    $r->rflush;
    
    while (1) {
        my $progress = $redis->get('progress');
        last unless defined $progress;
        
        print "data: $progress\n\n";
        $r->rflush;
        
        last if $progress >= 100.0;
        select(undef, undef, undef, 0.3);
    }
    return Apache2::Const::OK;
}
1;