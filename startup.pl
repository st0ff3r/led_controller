use lib qw(/led_controller);

use Embperl;
use Data::Dumper;
use LedController;
use LedController::Artnet;
use LedController::Session;
use LedController::Upload;
use LedController::Progress;

use POSIX qw(SIGTERM SIGINT);

# This intercepts the signal at the process level
$SIG{TERM} = sub {
	warn "[startup.pl] Received SIGTERM, cleaning up buffers...\n";
	STDERR->flush;
	STDOUT->flush;
	exit 0; 
};

1;
