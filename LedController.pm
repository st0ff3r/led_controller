package LedController;
use strict;
use File::Temp qw( tempfile tempdir );
use File::Copy;
use Image::Magick;
use Image::Size;
use Config::Simple;
use File::Path qw(remove_tree);
use Proc::Killall;
use Redis;

use constant ARTNET_CONF => '/led_controller/artnet.conf';
use constant SLITSCAN_IMAGE_MAX_HEIGHT => 10000;
use constant REDIS_HOST => '127.0.0.1';
use constant REDIS_PORT => '6379';

my $config = new Config::Simple(ARTNET_CONF);

sub new {
    my $class = shift;
    my $self = {
        redis => Redis->new(server => REDIS_HOST . ':' . REDIS_PORT)
    };
    bless $self, $class;
    return($self);
}

# Helper to keep progress reporting clean
sub update_progress {
    my ($self, $val) = @_;
    $self->{redis}->set('progress', sprintf("%.1f", $val));
}

sub movie_to_artnet {
    my ($self, %p) = @_;
    my $movie_file = $p{movie_file};
    my $artnet_data_file = $p{artnet_data_file};
    my $loop = $p{loop_forth_and_back};

    $self->update_progress(50.0);
    
    # ... (Keep your existing FFmpeg/ffprobe logic here) ...
    # Inside your loops, replace $self->{redis}->set(...) with:
    # $self->update_progress($new_val);
    
    return 1;
}

sub movie_to_slitscan {
    my ($self, %p) = @_;
    # ... (Keep existing write logic) ...
    $self->update_progress(100.0);
    sleep 2;
}

sub cleanup_temp_files {
    my ($self, $movie_file, $temp_dir, $temp_data) = @_;
    unlink($movie_file, $temp_data);
    remove_tree($temp_dir) if $temp_dir;
    $self->{redis}->del('progress', 'system_locked');
}

1;
