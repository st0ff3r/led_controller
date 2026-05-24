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

    # Initial progress
    my $val = $redis->get('progress') || 0;
    $r->print("data: $val\n\n");
    $r->rflush();

    # Callback to relay messages
    my $sub_callback = sub {
        my ($message, $topic) = @_;
        $r->print("data: $message\n\n");
        $r->rflush();
        # Exit subscription if finished
        die "DONE" if $message eq '100.0' || $message eq 'DONE';
    };

    eval {
        $subscriber->subscribe('progress_channel', $sub_callback);
        while (1) { $subscriber->wait_for_messages(10); }
    };
    
    $redis->del('progress');
    return Apache2::Const::OK;
}
1;
