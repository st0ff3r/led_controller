#!/usr/bin/perl -w

use strict;
use Config::Simple;
use Time::HiRes qw(usleep gettimeofday tv_interval);
use Redis;
use IO::Socket::INET;
use Sys::Hostname;
use Data::Dumper;

use constant ARTNET_CONF => 'artnet.conf';

$| = 1; # Force autoflush

my $config = new Config::Simple(ARTNET_CONF);
my $redis = Redis->new(server => 'redis:6379');

my $artnet_listener_timeout = $config->param('artnet_listener_timeout') || 10;

my $socket = new IO::Socket::INET (
	LocalPort	=> '6454',
	Proto		=> 'udp'
) || die "ERROR in socket creation : $!\n";

my (
	$opcode_h,
	$opcode_l,
	$protocol_version_h,
	$protocol_version_l,
	$sequence,
	$physical,
	$universe_h,
	$universe_l,
	$length_h,
	$length_l
);
my ($length, $opcode, $universe, $dmx);

my $last_received_time = time();

# Initial state
set_intensity(1.0);

while (1) {
	# Non-blocking check for ArtNet packets with a short timeout to handle watchdog
	my $recieved_data;
	$socket->recv($recieved_data, 1024, MSG_DONTWAIT);
	
	if ($recieved_data) {
		$last_received_time = time();

		$opcode_l = vec($recieved_data, 8, 8);
		$opcode_h = vec($recieved_data, 9, 8);
		
		$universe_h = vec($recieved_data, 14, 8);
		$universe_l = vec($recieved_data, 15, 8);
		$length_h = vec($recieved_data, 16, 8);
		$length_l = vec($recieved_data, 17, 8);

		$opcode = $opcode_h << 8 | $opcode_l;
		$length = $length_h << 8 | $length_l;
		$universe = $universe_h << 8 | $universe_l;

		if ($opcode == 0x5000) {	# ArtNet packet
			if ($length <= 512 && $universe == $config->param('my_universe')) {
				$dmx = vec($recieved_data, 18, 8);
				set_intensity($dmx / 255);
			}
		}
		elsif ($opcode == 0x2000) {	# ArtPoll packet
			my $peer_ip = $socket->peerhost;
			my $socket_reply = new IO::Socket::INET (
				PeerAddr => $peer_ip . ":6454",
				Proto    => 'udp'
			) || warn "ERROR in reply socket: $!\n";

			if ($socket_reply) {
				my $host_ip = $socket_reply->sockhost;
				my $packet = "Art-Net\x00\x00\x21" . join('', map({chr $_} split(/\./, $host_ip))) . "\x36\x19" . 
					"\x04\x20" . "\x00\x00" . "\xff\xff" . "\x00" . "\xf0" . "\xff\xff" .
					"Trappe LED" . "\x00" x 8 . "Trappe LED" . "\x00" x 54 .
					"\x00" x 64 . "\x00\x01" . "\x80\x80\x80\x80" . "\x00" x 35;
				$socket_reply->send($packet);
				$socket_reply->close();
			}
		}
	}

	# Simple watchdog check
	if ($last_received_time + $artnet_listener_timeout < time()) {
		print "ArtNet timeout\n";
		set_intensity(1.0);
		$last_received_time = time(); # Reset to avoid spamming
	}

	usleep(10000); # 10ms sleep to prevent CPU spiking
}

sub set_intensity {
	my $intensity = shift;
	
	# Update Redis instead of IPC::ShareLite
	$redis->set('intensity_artnet', $intensity);
	
	# Publish update to trigger send_artnet_data
	$redis->publish('intensity_update', 'refresh');
}

1;
