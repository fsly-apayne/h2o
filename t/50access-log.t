use strict;
use warnings;
use File::Temp qw(tempdir);
use Net::EmptyPort qw(empty_port check_port);
use JSON qw(decode_json);
use Test::More;
use t::Util;

my $client_prog = bindir() . "/h2o-httpclient";
plan skip_all => "$client_prog not found"
    unless -e $client_prog;
plan skip_all => 'curl not found'
    unless prog_exists('curl');
plan skip_all => 'racy under valgrind' if $ENV{"H2O_VALGRIND"};

my $tempdir = tempdir(CLEANUP => 1);
my $upstream_port = empty_port();
my $upstream = spawn_server(
    argv     => [ qw(plackup -s Starlet --keepalive-timeout 100 --access-log /dev/null --listen), $upstream_port, ASSETS_DIR . "/upstream.psgi" ],
    is_ready =>  sub {
        check_port($upstream_port);
    },
);

sub doit {
    my ($cmd, $args, @expected) = @_;

    unlink "$tempdir/access_log";

    $args = { format => $args }
        unless ref $args;
    my $quic_port = empty_port({ host  => "0.0.0.0", proto => "udp" });
    my $server = spawn_h2o({conf => <<"EOT", max_ssl_version => 'TLSv1.2'});
num-threads: 1
listen:
  type: quic
  port: $quic_port
  ssl:
    key-file: examples/h2o/server.key
    certificate-file: examples/h2o/server.crt
hosts:
  default:
    paths:
      /:
        file.dir: @{[ DOC_ROOT ]}
      /fastcgi:
        fastcgi.connect:
          port: /nonexistent
          type: unix
        error-log.emit-request-errors: OFF
      /set-cookie:
        file.dir: @{[ DOC_ROOT ]}
        header.add: "set-cookie: a=b"
        header.add: "set-cookie: c=d"
        header.add: "cache-control: must-revalidate"
        header.add: "cache-control: no-store"
      /compress:
        file.dir: @{[ DOC_ROOT ]}
        compress: [gzip]
      /proxy:
        proxy.reverse.url: http://127.0.0.1:$upstream_port
    access-log:
      format: '$args->{format}'
@{[$args->{escape} ? "      escape: $args->{escape}" : ""]}
      path: $tempdir/access_log
EOT

    $server->{quic_port} = $quic_port;
    $cmd->($server);

    undef $server->{guard}; # log will be emitted before the server exits

    my @log = do {
        open my $fh, "<", "$tempdir/access_log"
            or die "failed to open access_log:$!";
        map { my $l = $_; chomp $l; $l } <$fh>;
    };

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    for (my $i = 0; $i != @expected; ++$i) {
        if (ref $expected[$i] eq 'CODE') {
            $expected[$i]->($log[$i], $server);
        } else {
            like $log[$i], $expected[$i];
        }
    }
}

subtest "custom-log" => sub {
    doit(
        sub {
            my $server = shift;
            system("curl --silent --referer http://example.com/ http://127.0.0.1:$server->{port}/ > /dev/null");
        },
        '%h %l %u %t "%r" %s %b "%{Referer}i" "%{User-agent}i"',
        qr{^127\.0\.0\.1 - - \[[0-9]{2}/[A-Z][a-z]{2}/20[0-9]{2}:[0-9]{2}:[0-9]{2}:[0-9]{2} [+\-][0-9]{4}\] "GET / HTTP/1\.1" 200 6 "http://example.com/" "curl/.*"$},
    );
};

subtest "strftime" => sub {
    doit(
        sub {
            my $server = shift;
            system("curl --silent http://127.0.0.1:$server->{port}/ > /dev/null");
        },
        '%{%Y-%m-%dT%H:%M:%S}t',
        qr{^20[0-9]{2}-(?:0[1-9]|1[012])-(?:[012][0-9]|3[01])T[0-9]{2}:[0-9]{2}:[0-9]{2}$},
    );
};

subtest "strftime-special" => sub {
    doit(
        sub {
            my $server = shift;
            system("curl --silent http://127.0.0.1:$server->{port}/ > /dev/null");
        },
        '%{msec_frac}t::%{usec_frac}t::%{sec}t::%{msec}t::%{usec}t',
        qr{^([0-9]{3})::(\1[0-9]{3})::([0-9]+)::\3\1::\3\2$},
    );
};

subtest "more-fields" => sub {
    my $local_port = "";
    doit(
        sub {
            my $server = shift;
            my $resp = `curl --silent -w ',\%{local_port}' http://127.0.0.1:$server->{port}/`;
            like $resp, qr{,(\d+)$}s;
            $local_port = do { $resp =~ /,(\d+)$/s; $1 };
        },
        '"%A:%p" "%{local}p" "%{remote}p"',
        sub {
            my($log, $server) = @_;
            like $log, qr{^\"127\.0\.0\.1:$server->{port}\" \"$server->{port}\" \"$local_port\"$};
        },
    );
};

subtest 'ltsv-related' => sub {
    doit(
        sub {
            my $server = shift;
            system("curl --silent http://127.0.0.1:$server->{port} > /dev/null");
            system("curl --silent http://127.0.0.1:$server->{port}/query?abc=d > /dev/null");
        },
        '%m::%U%q::%H::%V::%v',
        qr{^GET::/::HTTP/1\.1::127\.0\.0\.1:[0-9]+::default$},
        qr{^GET::/query\?abc=d::HTTP/1\.1::127\.0\.0\.1:[0-9]+::default$},
    );
};

subtest 'timings' => sub {
    # The path should take at least 0.050 sec in total.
    # See also 50reverse-proxy-timings.t for timing stats.
    my $path = "proxy/streaming-body?sleep=0.01&count=5";
    my $least_duration = 0.040; # 0.50 is too sensitive

    my $doit = sub {
        my ($opts, $expected_status_line, $expected_protocol) = @_;
        doit(
            sub {
                my ($server) = @_;
                my $port = $expected_protocol ne "HTTP/3" ? $server->{tls_port} : $server->{quic_port};
                my $resp = `$client_prog -k $opts 'https://127.0.0.1:$port/$path' 2>&1`;
                like $resp, $expected_status_line, "HTTP request for $expected_protocol";
            },
            {
                format => '{
                    "protocol":"%H"
                    , "connect-time":%{connect-time}x
                    , "request-total-time":%{request-total-time}x
                    , "request-header-time":%{request-header-time}x
                    , "request-body-time":%{request-body-time}x
                    , "process-time":%{process-time}x
                    , "response-time":%{response-time}x
                    , "duration":%{duration}x
                    , "total-time":%{total-time}x
                    , "proxy.idle-time":%{proxy.idle-time}x
                    , "proxy.connect-time":%{proxy.connect-time}x
                    , "proxy.request-time":%{proxy.request-time}x
                    , "proxy.process-time":%{proxy.process-time}x
                    , "proxy.response-time":%{proxy.response-time}x
                    , "proxy.total-time":%{proxy.total-time}x
                }',
                escape => 'json',
            },
            sub {
                my($log_json) = @_;
                my $log = decode_json($log_json);

                is $log->{"protocol"}, $expected_protocol;

                cmp_ok $log->{"connect-time"}, ">", 0;
                cmp_ok $log->{"request-total-time"}, ">=", 0;
                cmp_ok $log->{"request-header-time"}, ">=", 0;
                cmp_ok $log->{"request-body-time"}, ">=", 0;
                cmp_ok $log->{"process-time"}, ">=", 0;
                cmp_ok $log->{"response-time"}, ">=", $least_duration;
                cmp_ok $log->{"total-time"}, ">=", $least_duration;
                cmp_ok $log->{"duration"}, ">=", $least_duration;
                cmp_ok $log->{"proxy.idle-time"}, ">=", 0;
                cmp_ok $log->{"proxy.connect-time"}, ">", 0;
                cmp_ok $log->{"proxy.request-time"}, ">=", 0;
                cmp_ok $log->{"proxy.process-time"}, ">", 0;
                cmp_ok $log->{"proxy.response-time"}, ">", $least_duration;
                cmp_ok $log->{"proxy.total-time"}, ">", $least_duration;
            },
        );
    };
    subtest 'http1' => sub {
        $doit->("", qr{^HTTP/1\.1 200\b}ms, "HTTP/1.1");
    };
    subtest 'http2' => sub {
        $doit->("-2 100", qr{^HTTP/2 200\b}ms, "HTTP/2");
    };
    subtest 'http3' => sub {
        $doit->("-3 100", qr{^HTTP/3 200\b}ms, "HTTP/3");
    };
};

subtest 'header-termination (issue 462)' => sub {
    doit(
        sub {
            my $server = shift;
            system("curl --user-agent foobar/1 --silent http://127.0.0.1:$server->{port} > /dev/null");
        },
        '%{user-agent}i',
        qr{^foobar/1$},
    );
    doit(
        sub {
            my $server = shift;
            system("curl --user-agent foobar/1 --silent http://127.0.0.1:$server->{port} > /dev/null");
        },
        '%{content-type}o',
        qr{^text/plain$},
    );
};

subtest 'extensions' => sub {
    doit(
        sub {
            my $server = shift;
            sleep 1; # ensure check_port's SYN_ACK is delivered to the server before that generated by curl
            system("curl --silent http://localhost:$server->{port}/ > /dev/null");
            system("curl --silent --insecure @{[curl_supports_http2() ? ' --http1.1' : '']} https://localhost:$server->{tls_port}/ > /dev/null");
            system("curl --silent --insecure @{[curl_supports_http2() ? ' --http1.1' : '']} https://127.0.0.1:$server->{tls_port}/ > /dev/null");
            if (prog_exists("nghttp")) {
                system("nghttp -n https://localhost:$server->{tls_port}/");
                system("nghttp -n --weight=22 https://localhost:$server->{tls_port}/");
            }
        },
        '%{connection-id}x %{ssl.protocol-version}x %{ssl.session-reused}x %{ssl.cipher}x %{ssl.cipher-bits}x %{ssl.server-name}x %{http2.stream-id}x %{http2.priority.received}x',
        do {
            my @expected = (
                qr{^2 - - - - - - -$}is,
                qr{^3 TLSv[0-9.]+ 0 \S+RSA\S+ (?:128|256) localhost - -$}is,
                qr{^4 TLSv[0-9.]+ 0 \S+RSA\S+ (?:128|256) - - -$}is,
            );
            if (prog_exists("nghttp")) {
                push @expected, +(
                    qr{^5 TLSv[0-9.]+ 0 \S+RSA\S+ (?:128|256) localhost [0-9]*[13579] 0:[0-9]+:16}is,
                    qr{^6 TLSv[0-9.]+ 0 \S+RSA\S+ (?:128|256) localhost [0-9]*[13579] 0:[0-9]+:22}is,
                );
            }
            @expected;
        },
    );
};

subtest 'ssl-log' => sub {
    doit(
        sub {
            my $server = shift;
            system("curl --silent -k https://127.0.0.1:$server->{tls_port}/ > /dev/null");
        },
        '%{ssl.session-id}x',
        qr{^\S+$}s,
    );
};

subtest 'error' => sub {
    doit(
        sub {
            my $server = shift;
            system("curl --silent http://127.0.0.1:$server->{port}/fastcgi > /dev/null");
        },
        '%{error}x',
        qr{^\[lib/handler/fastcgi\.c\] in request:/fastcgi:connection failed:}s,
    );
};

subtest 'set-cookie' => sub {
    # set-cookie header is the only header to be concatenated with %{...}o, according to Apache
    doit(
        sub {
            my $server = shift;
            system("curl --silent http://127.0.0.1:$server->{port}/set-cookie/ > /dev/null");
        },
        '"%<{set-cookie}o" "%>{set-cookie}o" "%{set-cookie}o" "%{cache-control}o"',
        qr{^"-" "a=b, c=d" "a=b, c=d" "must-revalidate"$}s,
    );
};

subtest 'escape' => sub {
    for my $i ([default => qr{^/\\xe3\\x81\\x82$}s], [apache => qr{^/\\xe3\\x81\\x82$}s], [json => qr{^/\\u00e3\\u0081\\u0082$}s]) {
        my ($escape, $expected) = @$i;
        subtest $escape => sub {
            doit(
                sub {
                    my $server = shift;
                    system("curl --silent http://127.0.0.1:$server->{port}/\xe3\x81\x82 > /dev/null");
                },
                $escape eq 'default' ? '%U' : { format => '%U', escape => $escape },
                $expected,
            );
        };
    }
};

subtest "json-null" => sub {
    doit(
        sub {
            my $server = shift;
            system("curl --silent http://127.0.0.1:$server->{port}/ > /dev/null");
        },
        # single specifier surrounded by quotes that consist a string literal in JSON should be converted to `null` if the specifier
        # resolves to null
        { format => q{"%h" %l "%l" ''%l'' ''%l '' ''"%l"''}, escape => 'json' },
        qr{^"127\.0\.0\.1" null null null 'null ' '"null"'$},
    );
};

subtest 'compressed-body-size' => sub {
    my $doit = sub {
        my ($opts, $expected) = @_;
        doit(
            sub {
                my $server = shift;
                system("curl $opts --silent http://127.0.0.1:$server->{port}/compress/alice.txt > /dev/null");
            },
            '%b',
            qr{^$expected$},
        );
    };
    subtest 'http1' => sub {
        $doit->("", 1661);
        $doit->("-H 'Accept-Encoding: gzip'", 908); # it doesn't contain chunked encoding overhead (12)
    };
    subtest 'http2' => sub {
        plan skip_all => "curl does not support HTTP/2"
            unless curl_supports_http2();
        $doit->("--http2", 1661);
        $doit->("--http2 -H 'Accept-Encoding: gzip'", 908);
    };
};

done_testing;
