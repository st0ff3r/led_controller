#!/usr/bin/perl -w

use strict;
use Config::Simple;
use Redis;
use Data::Dumper;

use constant ARTNET_CONF => 'artnet.conf';

$| = 1; # Force autoflush

# Connect to the Redis container
my $redis_socket = $ENV{REDIS_SOCKET} || die "REDIS_SOCKET environment variable not set";
my $redis = Redis->new(sock => $redis_socket) or die "Failed to connect to Redis socket: $!";

my $config = new Config::Simple(ARTNET_CONF);

my $intensity = $ARGV[0];

# Update intensity in Redis
$redis->set('intensity', $intensity);

# Publish update so send_artnet_data.pl picks up the new value
$redis->publish('intensity_update', 'refresh');

print "Intensity set to $intensity and update published.\n";
