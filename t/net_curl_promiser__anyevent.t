#!/usr/bin/env perl

# Copyright 2020 cPanel, L. L. C.
# All rights reserved.
# http://cpanel.net
#
# This is free software; you can redistribute it and/or modify it under the
# same terms as Perl itself. See L<perlartistic>.

package t::net_curl_promiser__anyevent;

use strict;
use warnings;
use autodie;

use FindBin;
use lib "$FindBin::Bin/lib";

use parent (
    'TestHTTPBase',
    'TestHTTPUAPIMixin',
);

use Test::More;
use Test::Deep;
use Test::FailWarnings;

__PACKAGE__->new()->runtests() if !caller;

use constant _CP_REQUIRE => (
    'AnyEvent::Loop',
    sub { diag "Using AnyEvent $AnyEvent::VERSION"; },
    'Net::Curl::Promiser::AnyEvent',
    sub { diag Net::Curl::version(); },
    sub { diag "Using Net::Curl $Net::Curl::VERSION"; },
    sub { diag "Using Net::Curl::Promiser $Net::Curl::Promiser::VERSION" },
    'Promise::ES6',
    sub { diag "Promise::ES6 $Promise::ES6::VERSION" },
);

sub TRANSPORT_PIECE {
    my ($self) = @_;

    $self->{'_promiser'} ||= do {
        Net::Curl::Promiser::AnyEvent->new();
    };

    return ( 'NetCurlPromiser', promiser => $self->{'_promiser'} );
}

sub AWAIT {
    my ( $self, $pending ) = @_;

    my ( $ok, $value, $reason );

    my $cv = AnyEvent->condvar();
    $pending->promise()->then(
        sub { $value = shift; $ok = 1 },
        sub { $reason = shift },
    )->finally($cv);
    $cv->recv();

    die $reason if !$ok;

    return $value;
}

sub test_uapi_cancel : Tests(2) {
    my ($self) = @_;

    no warnings 'once';
    local $cPanel::APIClient::DEBUG = 1;

  SKIP: {
        my $version = $Net::Curl::Promiser::VERSION;
        my $min_version = 0.12;
        if ( $version < $min_version ) {
            skip "This test requires Net::Curl::Promiser $min_version or newer.", $self->num_tests();
        }

        # We don’t cancel() the request immediately because that’ll prompt
        # a connect warning in MockCpsrvd.pm. So instead we stop the event
        # loop on the first write, cancel the request, then resume the loop
        # so that the cancellation plays out “naturally”.

        my $cv1 = AnyEvent->condvar();

        local $cPanel::APIClient::Transport::NetCurlPromiser::_TWEAK_EASY_CR = sub {
            my ($easy) = @_;

            require Net::Curl::Easy;
            $easy->setopt(
                Net::Curl::Easy::CURLOPT_WRITEFUNCTION(),
                sub {
                    my ( $easy, $data, $uservar ) = @_;

                    $cv1->();

                    return length $data;
                }
            );
        };

        my $remote_cp = $self->CREATE(
            service => 'cpanel',

            credentials => {
                username  => 'johnny',
                api_token => 'MYTOKEN',
            },
        );

        my $pending = $remote_cp->call_uapi( 'Whatsit', 'heyhey' );

        my $fate;

        my $main_p = $pending->promise();
        diag "main promise: $main_p";

        {
            my $sub_p = $main_p->then(
                sub { $fate = [0, shift()] },
                sub { $fate = [1, shift()] },
            );

            diag "2nd promise: $sub_p";
        }

        $cv1->recv();

        is( $fate, undef, 'promise for canceled request doesn’t resolve' ) or diag explain $fate;

        if ($fate) {
            skip 'Wait … we already finished what we were about to cancel?? That’s weird.', 1;
        }

        $remote_cp->cancel( $pending );

        my $cv2 = AnyEvent->condvar();

        my $timeout = AnyEvent->timer(
            after => 1,
            cb => $cv2,
        );

        $cv2->recv();

        is( $fate, undef, 'promise for canceled request still doesn’t resolve' ) or diag explain $fate;
    }

    return;
}

1;
