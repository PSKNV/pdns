# our chosen base image
FROM debian:10-slim AS builder

# TODO: make sure /source looks roughly the same from git or tar

# Reusable layer for base update
RUN apt-get update && apt-get -y dist-upgrade && apt-get clean

# devscripts gives us mk-build-deps (and a lot of other stuff)
RUN apt-get update && apt-get -y dist-upgrade && apt-get install -y  --no-install-recommends devscripts equivs git && apt-get clean

# RUN ls -lah /source
RUN git clone --depth 1 https://github.com/PSKNV/pdns.git /source/

# import everything - this could be pdns.git OR an auth tarball!
# COPY builder-support /source/builder-support

# TODO: control file is not in tarballs at all right now
RUN mk-build-deps -i -t 'apt-get -y -o Debug::pkgProblemResolver=yes --no-install-recommends' /source/builder-support/debian/authoritative/debian-buster/control && \
    apt-get clean

# build and install (TODO: before we hit this line, rearrange /source structure if we are coming from a tarball)
WORKDIR /source/

RUN git submodule init; git submodule update

RUN cp /source/builder/helpers/set-configure-ac-version.sh /usr/local/bin

ARG MAKEFLAGS=
ENV MAKEFLAGS ${MAKEFLAGS:--j2}

ARG DOCKER_FAKE_RELEASE=NO
ENV DOCKER_FAKE_RELEASE ${DOCKER_FAKE_RELEASE}

RUN if [ "${DOCKER_FAKE_RELEASE}" = "YES" ]; then \
      BUILDER_VERSION="$(BUILDER_MODULES=authoritative ./builder-support/gen-version | sed 's/\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/')" set-configure-ac-version.sh;\
    fi && \
    BUILDER_MODULES=authoritative autoreconf -vfi

# simplify repeated -C calls with SUBDIRS?
RUN mkdir /build && \
    ./configure \
      --with-lua=luajit \
      --sysconfdir=/etc/powerdns \
      --enable-option-checking=fatal \
      --with-dynmodules='bind geoip gmysql godbc gpgsql gsqlite3 ldap lmdb lua2 pipe random remote tinydns' \
      --enable-tools \
      --enable-ixfrdist && \
    make clean && \
    make $MAKEFLAGS -C ext && make $MAKEFLAGS -C modules && make $MAKEFLAGS -C pdns && \
    make -C pdns install DESTDIR=/build && make -C modules install DESTDIR=/build && make clean && \
    strip /build/usr/local/bin/* /build/usr/local/sbin/*
RUN cd /tmp && mkdir /build/tmp/ && mkdir debian && \
    echo 'Source: pdns' > debian/control && \
    dpkg-shlibdeps /build/usr/local/bin/* /build/usr/local/sbin/* /build/usr/local/lib/pdns/*.so && \
    sed 's/^shlibs:Depends=/Depends: /' debian/substvars >> debian/control && \
    equivs-build debian/control && \
    dpkg-deb -I equivs-dummy_1.0_all.deb && cp equivs-dummy_1.0_all.deb /build/tmp/

# Runtime
FROM debian:10-slim

# Reusable layer for base update - Should be cached from builder
RUN apt-get update && apt-get -y dist-upgrade && apt-get clean

# Ensure python3 and jinja2 is present (for startup script), and sqlite3 (for db schema), and tini (for signal management)
RUN apt-get install -y python3 python3-jinja2 sqlite3 tini libcap2-bin && apt-get clean

# Output from builder
COPY --from=builder /build /
RUN chmod 1777 /tmp # FIXME: better not use /build/tmp for equivs at all
RUN setcap 'cap_net_bind_service=+eip' /usr/local/sbin/pdns_server

# Ensure dependencies are present
RUN apt install -y /tmp/equivs-dummy_1.0_all.deb && apt clean

# Start script
COPY dockerdata/startup.py /usr/local/sbin/pdns_server-startup

COPY dockerdata/pdns.conf /etc/powerdns/
RUN mkdir -p /etc/powerdns/pdns.d /var/run/pdns /var/lib/powerdns /etc/powerdns/templates.d

# Work with pdns user - not root
RUN adduser --system --disabled-password --disabled-login --no-create-home --group pdns --uid 953
RUN chown pdns:pdns /var/run/pdns /var/lib/powerdns /etc/powerdns/pdns.d /etc/powerdns/templates.d
USER pdns

# Set up database - this needs to be smarter
RUN sqlite3 /var/lib/powerdns/pdns.sqlite3 < /usr/local/share/doc/pdns/schema.sqlite3.sql

# DNS ports
EXPOSE 53/udp
EXPOSE 53/tcp
# webserver port
EXPOSE 8081/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/sbin/pdns_server-startup"]
