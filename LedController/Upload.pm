package LedController::Upload;
use strict;
use Apache2::RequestRec;
use Apache2::Const qw(:common);
use File::Temp qw(tempfile);
use Redis;
use LedController;

sub handler {
    my $r = shift;
    my $redis = Redis->new(server => '127.0.0.1:6379');

    # Atomar lås: Hvis 'system_locked' findes, returner FORBIDDEN
    if (!$redis->set('system_locked', '1', 'NX')) {
        return FORBIDDEN;
    }

    my $c = LedController->new();
    my $q = CGI->new;
    
    if (my $fh_in = $q->upload('movie_file')) {
        my ($fh_out, $temp_file) = tempfile(DIR => '/tmp', SUFFIX => '.mov', UNLINK => 0);
        while (<$fh_in>) { print $fh_out $_; }
        close $fh_out;
        
        # Send job til worker
        $redis->rpush('job_queue', $temp_file);
        return OK;
    }
    
    $redis->del('system_locked');
    return BAD_REQUEST;
}

1;
