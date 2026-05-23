#!/usr/bin/perl
use strict;
use Redis;
use LedController;

my $redis = Redis->new(server => '127.0.0.1:6379');
my $c = LedController->new();

while (1) {
    # Wait for job in the queue (blpop blocks until data arrives)
    my ($queue, $job_file) = $redis->blpop('job_queue', 0);
    
    # Set system_locked and reset progress
    $redis->set('system_locked', '1');
    $redis->set('progress', '0');

    # Run processing and pass the redis object for progress reporting
    # You must ensure LedController.pm uses this $redis handle to update 'progress'
    if ($c->movie_to_artnet(
        movie_file => $job_file, 
        artnet_data_file => "/led_controller/data/artnet.data", 
        loop_forth_and_back => 1,
        redis => $redis # Pass redis to controller
    )) {
        # Update progress for the next step
        $redis->set('progress', '90');
        $c->movie_to_slitscan(slitscan_file => "/var/www/led_controller/images/slitscan.png");
    }

    # Cleanup and release locks
    $c->cleanup_temp_files();
    $redis->del('system_locked');
    $redis->set('progress', '100'); # Signal completion
    
    unlink($job_file);
}
