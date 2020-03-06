CC=g++
CFLAGS=-std=gnu++0x -static -O3 -Wfatal-errors -Werror -pthread
LDFLAGS=-lcrypt -lboost_filesystem -lboost_system -lboost_regex -lev

all:	build

build:
	apt install -y libboost-all-dev libev-dev libmemcached-dev
	cd ./cpp && \
	$(CC) $(CFLAGS) dklab_realplexor.cpp $(LDFLAGS) -o ../dklab_realplexor

install:
	install -m 755 dklab_realplexor /usr/sbin/
	install -m 644 dklab_realplexor.conf /etc/
	install -m 644 dklab_realplexor.service /lib/systemd/system/
	install -d /usr/lib/dklab_realplexor
	install dklab_realplexor.html /usr/lib/dklab_realplexor
	install dklab_realplexor.htpasswd /usr/lib/dklab_realplexor
	install dklab_realplexor.js /usr/lib/dklab_realplexor
	cp -r perl /usr/lib/dklab_realplexor/

build-deb:
	checkinstall -D --requires libev-perl --maintainer gm --reset-uids=yes --install=no --backup=no
