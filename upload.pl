#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use File::Temp qw( tempfile );
use Time::HiRes qw(usleep gettimeofday tv_interval);
use Apache2::RequestUtil;
use Apache2::Const;
use CGI;

use lib qw ( /led_controller );
use LedController;

my $timestamp = int (gettimeofday * 1000);
my $c = new LedController;

my $r = Apache2::RequestUtil->request;
$r->pool->cleanup_register(\&cleanup, $c);
$r->content_type('text/html');

my $q = new CGI (\&hook);

if (defined $q->param('movie_file')) {
	my ($fh, $temp_file) = tempfile( CLEANUP => 0 );
	
	my $loop = $q->param('loop') || 1;
	
	my $buffer;
	while (read($q->param('movie_file'), $buffer, 26214400)) {	# max 25 MB
		print $fh $buffer;
	}
	close $fh;
	
	if ($c->movie_to_artnet(movie_file => $temp_file, artnet_data_file => "/led_controller/data/artnet.data", loop_forth_and_back => $loop)) {
		$c->movie_to_slitscan(slitscan_file => "/var/www/led_controller/images/slitscan.png");
	}
	
	unlink $temp_file;
}
return Apache2::Const::OK;


sub hook {
	my ($filename,$buffer,$bytes_read,$file) = @_;
	my $length = $ENV{'CONTENT_LENGTH'};

	my $uploading_progress = IPC::ShareLite->new(
		-key		=> 6455,
		-create		=> 'yes',
		-destroy	=> 'no'
	) or die $!;
		
	my $progress;
	if ($length > 0) {	# don't divide by zero.
		$progress = sprintf("%.1f", (( $bytes_read / $length ) * 50));	# uploading accounts for 50 % of total progress
		$uploading_progress->store($progress);
	}
}

sub cleanup {
	my $c = shift;
	$c->cleanup_temp_files;
}

1;

__END__