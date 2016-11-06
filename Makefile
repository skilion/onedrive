GDCARM = yes
DC = dmd
DFLAGS = -ofonedrive -L-lcurl -L-lsqlite3 -L-ldl
GDC = gdc
GDCFLAGS = -o onedrive
GDCLIBFLAGS = -lcurl -lsqlite3 -ldl

DESTDIR = /usr/local/bin
CONFDIR = /usr/local/etc

SOURCES = \
	src/config.d \
	src/itemdb.d \
	src/log.d \
	src/main.d \
	src/monitor.d \
	src/onedrive.d \
	src/sqlite.d \
	src/sync.d \
	src/upload.d \
	src/util.d

GDCPATCHES = \
	patch/etc_c_curl.d \
	patch/std_net_curl.d

ifeq ($(GDCARM),yes)
	UNAME_P  = $(shell uname -p -m)
else
	UNAME_P = any
endif

onedrive: $(SOURCES)
ifneq ($(filter arm%,$(UNAME_P)),)
	$(GDC) -frelease -fno-bounds-check $(GDCFLAGS) $(SOURCES) $(GDCPATCHES) $(GDCLIBFLAGS)
else
	$(DC) -O -release -inline -boundscheck=off $(DFLAGS) $(SOURCES)
endif

debug: $(SOURCES)
	$(DC) -debug -g -gs $(DFLAGS) $(SOURCES)

unittest: $(SOURCES)
	$(DC) -unittest -debug -g -gs $(DFLAGS) $(SOURCES)

clean:
	rm -f onedrive.o onedrive

install: onedrive onedrive.conf
	install onedrive $(DESTDIR)/onedrive
	install -m 644 onedrive.conf $(CONFDIR)/onedrive.conf
	install -m 644 onedrive.service /usr/lib/systemd/user

uninstall:
	rm -f $(DESTDIR)/onedrive
	rm -f $(CONFDIR)/onedrive.conf
	rm -f /usr/lib/systemd/user/onedrive.service
