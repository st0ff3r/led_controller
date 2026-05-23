FROM debian:bookworm

MAINTAINER Kristoffer Ek <stoffer@skulp.net>

# Enable non-free for Debian Bookworm
RUN echo "deb http://deb.debian.org/debian bookworm non-free non-free-firmware" >> /etc/apt/sources.list

RUN apt-get update && apt-get install -y \
	autoconf \
	automake \
	bash \
	bison \
	cpanminus \
	flex \
	g++ \
	gawk \
	gcc \
	git \
	inetutils-telnet \
	joe \
	make \
	sed \
	sudo \
	screen \
	rsync \
	redis-server \
	apache2 \
	apache2-bin \
	apache2-doc \
	apache2-utils \
	libapache2-mod-perl2 \
	libapache2-mod-perl2-dev \
	libapache2-mod-perl2-doc \
	libembperl-perl \
	libconfig-simple-perl \
	software-properties-common \
	libimage-magick-perl \
	libimage-size-perl \
	libipc-sharelite-perl \
	libdatetime-event-sunrise-perl \
	libdata-hexdump-perl \
	libredis-perl \
	libdata-uuid-perl \
	ffmpeg \
	imagemagick \
	tcpdump \
	&& rm -rf /var/lib/apt/lists/*

USER root

RUN mkdir -p /led_controller/data
RUN mkdir -p /var/www/led_controller/images
RUN chown -R www-data:www-data /led_controller
RUN chown -R www-data:www-data /var/www/led_controller

RUN PERL_MM_USE_DEFAULT=1 cpanm Proc::Killall
RUN PERL_MM_USE_DEFAULT=1 cpanm IO::Async::Timer::Periodic
RUN a2dismod -f deflate

COPY ./docker-entrypoint.sh /docker-entrypoint.sh
COPY ./artnet.conf /led_controller/

COPY ./LedController.pm /led_controller/
COPY ./LedController/Artnet.pm /led_controller/LedController/
COPY ./LedController/Session.pm /led_controller/LedController/
COPY ./LedController/Upload.pm /led_controller/LedController/
COPY ./LedController/Progress.pm /led_controller/LedController/
COPY ./artnetd.pl /led_controller/
COPY ./send_artnet_data.pl /led_controller/
COPY ./movie_to_artnet.pl /led_controller/
COPY ./led_control.pl /led_controller/
COPY ./sun_tracker.pl /led_controller/
COPY ./artnet_listener.pl /led_controller/
COPY ./test.mov /led_controller/

COPY ./000-default.conf /etc/apache2/sites-available/
COPY ./startup.pl /etc/apache2/perl/
COPY ./index.epl /var/www/led_controller/
COPY ./bootstrap.min.css /var/www/led_controller/
COPY ./bootstrap.min.css.map /var/www/led_controller/

ENTRYPOINT [ "/docker-entrypoint.sh" ]
