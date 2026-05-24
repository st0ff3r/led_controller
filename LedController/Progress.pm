sub handler {
    my $r = shift;
    
    # 1. Connection for polling/getting initial state
    my $redis_getter = Redis->new(server => 'redis:6379');
    
    # 2. Connection dedicated to Subscribing
    my $redis_sub = Redis->new(server => 'redis:6379');
    
    $r->content_type('text/event-stream');
    $r->headers_out->set('Cache-Control' => 'no-cache');
    $r->rflush();

    # Get current state first so the UI isn't empty if nothing is happening
    my $initial_val = $redis_getter->get('progress') || 0;
    $r->print("data: $initial_val\n\n");
    $r->rflush();

    # Define the callback that executes when a message arrives
    my $sub_callback = sub {
        my ($message, $topic, $subscribed_topic) = @_;
        $r->print("data: $message\n\n");
        $r->rflush();
        
        # Close connection/loop if task is finished
        if ($message eq '100.0' || $message eq 'DONE') {
            # Use 'die' or a flag to break the listen loop
            die "DONE"; 
        }
    };

    # Enter subscription mode
    eval {
        $redis_sub->subscribe('progress_channel', $sub_callback);
        # This blocks until we 'die' inside the callback
        while (1) {
            $redis_sub->wait_for_messages(10); 
        }
    };
    
    # Cleanup
    $redis_getter->del('system_locked', 'progress');
    
    return Apache2::Const::OK;
}
