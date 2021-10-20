package LedController;

use File::Temp qw( tempfile tempdir );
use File::Copy;
use Image::Magick;
use Image::Size;
use Config::Simple;
use Data::Dumper;

use constant ARTNET_CONF => '/led_controller/artnet.conf';

my $config = new Config::Simple(ARTNET_CONF);

sub new {
	my $class = shift;
	my %p = @_;
	my $self = {};

	$self->{slitscan_image} = new Image::Magick;
	
	bless $self, $class;

	return($self);
}

sub movie_to_artnet {
	my $self = shift;
	my %p = @_;
	
	my $movie_file = $p{movie_file};
	my $artnet_data_file = $p{artnet_data_file};
	my $loop_forth_and_back = $p{loop_forth_and_back} || undef;
	
	my $temp_dir = tempdir( CLEANUP => 1 );

	# convert movie to images
	#if (system("ffmpeg -loglevel -8 -i " . $movie_file . " -vf scale=" . $config->param('num_pixels') . ":-1:flags=neighbor " . "-filter:v fps=25 " . $temp_dir . "/%05d.png") != 0) {
	if (system("ffmpeg -loglevel -8 -i " . $movie_file . " -vf scale=" . $config->param('num_pixels') . ":-2:flags=neighbor " . $temp_dir . "/%05d.png") != 0) {
		warn "system failed: $?";
	}
	
	# get all images
	opendir(DIR, $temp_dir) || die "can't opendir $temp_dir: $!";
	my @images = grep { -f "$temp_dir/$_" } readdir(DIR);
	closedir DIR;

	# prepare slitscan image
	$self->{slitscan_image}->Set(size=>$config->param('num_pixels') . 'x' . scalar(@images));
	$self->{slitscan_image}->ReadImage('canvas:white');

	my ($image_size_x, $image_size_y);
	my $x;
	my ($fh, $temp_file) = tempfile( CLEANUP => 0 );
	my ($red, $green, $blue);

	@images = sort { $a cmp $b } @images;
	my $i = 0;
	foreach (@images) {
		($image_size_x, $image_size_y) = imgsize("$temp_dir/$_");
	
		my $p = new Image::Magick;
		$p->Read("$temp_dir/$_");
		for $x (0..$image_size_x) {
			($red, $green, $blue) = $p->GetPixel( 'x' => $x, 'y' => int($image_size_y / 2) );
			print $fh sprintf("%02x", int($red * 255)) . sprintf("%02x", int($green * 255)) . sprintf("%02x", int($blue * 255));
			
			$self->{slitscan_image}->SetPixel(x => $x, y => $i, color=> [$red, $green, $blue]);
		}
		print $fh "\n";
		$i++;
	}
	if ($loop_forth_and_back && @images >= 3) {
		@images = sort { $b cmp $a } @images;	# sort reversed
		shift(@images);	# remove first image
		pop(@images);	# remove last image
		foreach (@images) {
			($image_size_x, $image_size_y) = imgsize("$temp_dir/$_");
		
			my $p = new Image::Magick;
			$p->Read("$temp_dir/$_");
			for $x (0..$image_size_x) {
				($red, $green, $blue) = $p->GetPixel( 'x' => $x, 'y' => int($image_size_y / 2) );
				print $fh sprintf("%02x", int($red * 255)) . sprintf("%02x", int($green * 255)) . sprintf("%02x", int($blue * 255));
			}
			print $fh "\n";
		}
	}
	close($fh);
	move($temp_file, $artnet_data_file) || die $!;	
}

sub movie_to_slitscan {
	my $self = shift;
	my %p = @_;

	$self->{slitscan_image}->Write($p{slitscan_file});	
}

1;

__END__
