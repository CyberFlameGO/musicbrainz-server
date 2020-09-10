package t::MusicBrainz::Server::Controller::OAuth2;
use Test::Routine;
use Test::More;
use Test::Deep qw( cmp_set );
use utf8;

use Encode;
use HTTP::Request;
use URI;
use URI::QueryParam;
use JSON;
use MusicBrainz::Server::Test qw( html_ok );

with 't::Context', 't::Mechanize';

sub oauth_redirect_ok
{
    my ($mech, $host, $path, $state) = @_;

    is($mech->status, 302);
    my $uri = URI->new($mech->response->header('Location'));
    is($uri->scheme, 'http');
    is($uri->host, $host);
    is($uri->path, $path);
    is($uri->query_param('state'), $state);
    my $code = $uri->query_param('code');
    ok($code);

    return $code;
}

sub oauth_redirect_error
{
    my ($mech, $host, $path, $state, $error) = @_;

    is($mech->status, 302);
    my $uri = URI->new($mech->response->header('Location'));
    is($uri->scheme, 'http');
    is($uri->host, $host);
    is($uri->path, $path);
    is($uri->query_param('state'), $state);
    is($uri->query_param('error'), $error);
    is($uri->query_param('code'), undef);
}

sub oauth_authorization_code_ok
{
    my ($test, $code, $application_id, $editor_id, $offline) = @_;

    my $token = $test->c->model('EditorOAuthToken')->get_by_authorization_code($code);
    ok($token);
    is($token->application_id, $application_id);
    is($token->editor_id, $editor_id);
    is($token->authorization_code, $code);
    if ($offline) {
        isnt($token->refresh_token, undef);
    }
    else {
        is($token->refresh_token, undef);
    }
    is($token->access_token, undef);

    my $application = $test->c->model('Application')->get_by_id($application_id);
    $test->mech->post_ok('/oauth2/token', {
        client_id => $application->oauth_id,
        client_secret => $application->oauth_secret,
        redirect_uri => $application->oauth_redirect_uri || 'urn:ietf:wg:oauth:2.0:oob',
        grant_type => 'authorization_code',
        code => $code,
    });

    return $token;
}

test 'Authorize web workflow online' => sub {
    my $test = shift;

    MusicBrainz::Server::Test->prepare_test_database($test->c, '+oauth');

    my $client_id = 'id-web';
    my $redirect_uri = 'http://www.example.com/callback';

    # This requires login first
    $test->mech->get_ok('/oauth2/authorize?client_id=id-web&response_type=code&scope=profile&state=xxx&redirect_uri=http://www.example.com/callback');
    html_ok($test->mech->content);
    $test->mech->content_like(qr{You need to be logged in to view this page});

    # Logged in and now it asks for permission
    $test->mech->submit_form( with_fields => { username => 'editor1', password => 'pass' } );
    html_ok($test->mech->content);
    $test->mech->content_like(qr{Test Web is requesting permission});
    $test->mech->content_like(qr{View your public account information});
    $test->mech->content_unlike(qr{Perform the above operations when I'm not using the application});
    is($test->mech->response->header('X-Frame-Options'), 'DENY');

    # Deny the request
    $test->mech->max_redirect(0);
    $test->mech->submit_form( form_name => 'confirm', button => 'confirm.cancel' );
    oauth_redirect_error($test->mech, 'www.example.com', '/callback', 'xxx', 'access_denied');

    # Incorrect scope
    $test->mech->get("/oauth2/authorize?client_id=$client_id&response_type=code&scope=does-not-exist&state=xxx&redirect_uri=$redirect_uri");
    oauth_redirect_error($test->mech, 'www.example.com', '/callback', 'xxx', 'invalid_scope');
    is($test->mech->response->header('X-Frame-Options'), 'DENY');

    # Incorrect response type
    $test->mech->get("/oauth2/authorize?client_id=$client_id&response_type=yyy&scope=profile&state=xxx&redirect_uri=$redirect_uri");
    oauth_redirect_error($test->mech, 'www.example.com', '/callback', 'xxx', 'unsupported_response_type');
    is($test->mech->response->header('X-Frame-Options'), 'DENY');

    # https://tools.ietf.org/html/rfc6749#section-3.1
    # Request and response parameters MUST NOT be included more than once.
    my %dupe_test_params = (
        client_id => $client_id,
        response_type => 'code',
        scope => 'profile',
        state => 'xxx',
        redirect_uri => $redirect_uri,
    );
    for my $dupe_param (keys %dupe_test_params) {
        my $uri = URI->new;
        $uri->query_form(%dupe_test_params);
        my $content = ("$uri" =~ s/^\?//r) .
            "&$dupe_param=" . $dupe_test_params{$dupe_param};
        $test->mech->get('/oauth2/authorize?' . $content);
        is($test->mech->status, 400);
        $test->mech->content_like(qr{invalid_request});
        $test->mech->content_like(qr{Parameter is included more than once in the request: $dupe_param});
        is($test->mech->response->header('X-Frame-Options'), 'DENY');
    }

    # Authorize the request
    $test->mech->get_ok("/oauth2/authorize?client_id=$client_id&response_type=code&scope=profile&state=xxx&redirect_uri=$redirect_uri");
    $test->mech->submit_form( form_name => 'confirm', button => 'confirm.submit' );
    my $code = oauth_redirect_ok($test->mech, 'www.example.com', '/callback', 'xxx');
    is($test->mech->response->header('X-Frame-Options'), 'DENY');
    oauth_authorization_code_ok($test, $code, 2, 11, 0);

    # Try to authorize one more time, this time we should be redirected automatically and only get the access_token
    $test->mech->get("/oauth2/authorize?client_id=$client_id&response_type=code&scope=profile&state=yyy&redirect_uri=$redirect_uri");
    my $code2 = oauth_redirect_ok($test->mech, 'www.example.com', '/callback', 'yyy');
    isnt($code, $code2);
    is($test->mech->response->header('X-Frame-Options'), 'DENY');
    oauth_authorization_code_ok($test, $code2, 2, 11, 0);
};

test 'Authorize web workflow offline' => sub {
    my $test = shift;

    MusicBrainz::Server::Test->prepare_test_database($test->c, '+oauth');

    my $client_id = 'id-web';
    my $redirect_uri = 'http://www.example.com/callback';

    # Login first and disable redirects
    $test->mech->get_ok('/login');
    $test->mech->submit_form( with_fields => { username => 'editor1', password => 'pass' } );
    $test->mech->max_redirect(0);

    # Authorize first request
    $test->mech->get_ok("/oauth2/authorize?client_id=$client_id&response_type=code&scope=profile&state=xxx&access_type=offline&redirect_uri=$redirect_uri");
    html_ok($test->mech->content);
    $test->mech->content_like(qr{Test Web is requesting permission});
    $test->mech->content_like(qr{View your public account information});
    $test->mech->content_like(qr{Perform the above operations when I&#x27;m not using the application});
    $test->mech->submit_form( form_name => 'confirm', button => 'confirm.submit' );
    my $code = oauth_redirect_ok($test->mech, 'www.example.com', '/callback', 'xxx');
    oauth_authorization_code_ok($test, $code, 2, 11, 1);

    # Try to authorize one more time, this time we should be redirected automatically and only get the access_token
    $test->mech->get("/oauth2/authorize?client_id=$client_id&response_type=code&scope=profile&state=yyy&access_type=offline&redirect_uri=$redirect_uri");
    my $code2 = oauth_redirect_ok($test->mech, 'www.example.com', '/callback', 'yyy');
    isnt($code, $code2);
    oauth_authorization_code_ok($test, $code2, 2, 11, 0);

    # And one more time, this time force manual authorization
    $test->mech->get_ok("/oauth2/authorize?client_id=$client_id&response_type=code&scope=profile&state=yyy&access_type=offline&redirect_uri=$redirect_uri&approval_prompt=force");
    html_ok($test->mech->content);
    $test->mech->content_like(qr{Test Web is requesting permission});
    $test->mech->content_like(qr{View your public account information});
    $test->mech->content_like(qr{Perform the above operations when I&#x27;m not using the application});
    $test->mech->submit_form( form_name => 'confirm', button => 'confirm.submit' );
    my $code3 = oauth_redirect_ok($test->mech, 'www.example.com', '/callback', 'yyy');
    isnt($code, $code3);
    isnt($code2, $code3);
    oauth_authorization_code_ok($test, $code3, 2, 11, 1);
};

test 'Authorize desktop workflow oob' => sub {
    my $test = shift;

    MusicBrainz::Server::Test->prepare_test_database($test->c, '+oauth');

    my $client_id = 'id-desktop';
    my $redirect_uri = 'urn:ietf:wg:oauth:2.0:oob';

    # Login first and disable redirects
    $test->mech->get_ok('/login');
    $test->mech->submit_form( with_fields => { username => 'editor2', password => 'pass' } );
    $test->mech->max_redirect(0);

    # Authorize first request
    $test->mech->get_ok("/oauth2/authorize?client_id=$client_id&response_type=code&scope=profile&state=xxx&redirect_uri=$redirect_uri");
    html_ok($test->mech->content);
    $test->mech->content_like(qr{Test Desktop is requesting permission});
    $test->mech->content_like(qr{View your public account information});
    $test->mech->content_unlike(qr{Perform the above operations when I'm not using the application});
    $test->mech->submit_form( form_name => 'confirm', button => 'confirm.submit' );
    my $code = oauth_redirect_ok($test->mech, 'localhost', '/oauth2/oob', 'xxx');
    $test->mech->content_contains($code);
    oauth_authorization_code_ok($test, $code, 1, 12, 1);

    # Try to authorize one more time, this should ask for manual approval as well
    $test->mech->get_ok("/oauth2/authorize?client_id=$client_id&response_type=code&scope=profile&state=yyy&redirect_uri=$redirect_uri");
    html_ok($test->mech->content);
    $test->mech->content_like(qr{Test Desktop is requesting permission});
    $test->mech->content_like(qr{View your public account information});
    $test->mech->content_unlike(qr{Perform the above operations when I'm not using the application});
    $test->mech->submit_form( form_name => 'confirm', button => 'confirm.submit' );
    my $code2 = oauth_redirect_ok($test->mech, 'localhost', '/oauth2/oob', 'yyy');
    isnt($code, $code2);
    oauth_authorization_code_ok($test, $code2, 1, 12, 1);
};

test 'Authorize desktop workflow localhost' => sub {
    my $test = shift;

    MusicBrainz::Server::Test->prepare_test_database($test->c, '+oauth');

    my $client_id = 'id-desktop';
    my $redirect_uri = 'http://localhost:5678/cb';

    # Login first and disable redirects
    $test->mech->get_ok('/login');
    $test->mech->submit_form( with_fields => { username => 'editor2', password => 'pass' } );
    $test->mech->max_redirect(0);

    # Authorize first request
    $test->mech->get_ok("/oauth2/authorize?client_id=$client_id&response_type=code&scope=profile&state=xxx&redirect_uri=$redirect_uri");
    html_ok($test->mech->content);
    $test->mech->content_like(qr{Test Desktop is requesting permission});
    $test->mech->content_like(qr{View your public account information});
    $test->mech->content_unlike(qr{Perform the above operations when I'm not using the application});
    $test->mech->submit_form( form_name => 'confirm', button => 'confirm.submit' );
    my $code = oauth_redirect_ok($test->mech, 'localhost', '/cb', 'xxx');
    $test->mech->content_contains($code);
    oauth_authorization_code_ok($test, $code, 1, 12, 1);

    # Try to authorize one more time, this should ask for manual approval as well
    $test->mech->get_ok("/oauth2/authorize?client_id=$client_id&response_type=code&scope=profile&state=yyy&redirect_uri=$redirect_uri");
    html_ok($test->mech->content);
    $test->mech->content_like(qr{Test Desktop is requesting permission});
    $test->mech->content_like(qr{View your public account information});
    $test->mech->content_unlike(qr{Perform the above operations when I'm not using the application});
    $test->mech->submit_form( form_name => 'confirm', button => 'confirm.submit' );
    my $code2 = oauth_redirect_ok($test->mech, 'localhost', '/cb', 'yyy');
    isnt($code, $code2);
    oauth_authorization_code_ok($test, $code2, 1, 12, 1);
};

test 'Exchange authorization code' => sub {
    my $test = shift;

    MusicBrainz::Server::Test->prepare_test_database($test->c, '+oauth');

    my ($code, $response);

    # CORS preflight
    $test->mech->request(HTTP::Request->new(OPTIONS => '/oauth2/token'));
    $response = $test->mech->response;
    is($response->code, 200);
    is($response->header('allow'), 'POST, OPTIONS');
    is($response->header('access-control-allow-origin'), '*');

    # https://tools.ietf.org/html/rfc6749#section-3.2
    # Request and response parameters MUST NOT be included more than once.
    my %dupe_test_params = (
        client_id => 'abc',
        client_secret => 'abc',
        grant_type => 'authorization_code',
        redirect_uri => 'abc',
        code => 'abc',
    );
    for my $dupe_param (keys %dupe_test_params) {
        my $uri = URI->new;
        $uri->query_form(%dupe_test_params);
        my $content = ("$uri" =~ s/^\?//r) .
            "&$dupe_param=" . $dupe_test_params{$dupe_param};
        $test->mech->post('/oauth2/token', content => $content);
        $response = from_json($test->mech->content);
        is($test->mech->status, 400);
        is($response->{error}, 'invalid_request');
        is(
            $response->{error_description},
            'Parameter is included more than once in the request: ' . $dupe_param,
        );
    }

    # Unknown authorization code
    $code = "xxxxxxxxxxxxxxxxxxxxxx";
    $test->mech->post('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-desktop-secret',
        grant_type => 'authorization_code',
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
        code => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'invalid_grant');

    # Expired authorization code
    $code = "kEbi7Dwg4hGRFvz9W8VIuQ";
    $test->mech->post('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-desktop-secret',
        grant_type => 'authorization_code',
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
        code => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'invalid_grant');

    $code = "liUxgzsg4hGvDxX9W8VIuQ";

    # Missing client_id
    $test->mech->post('/oauth2/token', {
        client_secret => 'id-desktop-secret',
        grant_type => 'authorization_code',
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
        code => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 401);
    is($response->{error}, 'invalid_client');

    # Incorrect client_id
    $test->mech->post('/oauth2/token', {
        client_id => 'id-xxx',
        client_secret => 'id-desktop-secret',
        grant_type => 'authorization_code',
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
        code => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 401);
    is($response->{error}, 'invalid_client');

    # Missing client_secret
    $test->mech->post('/oauth2/token', {
        client_id => 'id-desktop',
        grant_type => 'authorization_code',
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
        code => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 401);
    is($response->{error}, 'invalid_client');

    # Incorrect client_secret
    $test->mech->post('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-xxx-secret',
        grant_type => 'authorization_code',
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
        code => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 401);
    is($response->{error}, 'invalid_client');

    # Missing grant_type
    $test->mech->post('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-desktop-secret',
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
        code => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'invalid_request');

    # Incorrect grant_type
    $test->mech->post('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-desktop-secret',
        grant_type => 'xxx',
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
        code => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'unsupported_grant_type');

    # Missing redirect_uri
    $test->mech->post('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-desktop-secret',
        grant_type => 'authorization_code',
        code => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'invalid_request');

    # Incorect redirect_uri
    $test->mech->post('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-desktop-secret',
        grant_type => 'authorization_code',
        redirect_uri => 'xxx',
        code => $code
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'invalid_request');

    # Missing code
    $test->mech->post('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-desktop-secret',
        grant_type => 'authorization_code',
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'invalid_request');

    # Correct code, but incorrect application
    $test->mech->post('/oauth2/token', {
        client_id => 'id-web',
        client_secret => 'id-web-secret',
        grant_type => 'authorization_code',
        redirect_uri => 'http://www.example.com/callback',
        code => $code
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'invalid_grant');

    # Correct parameters, but GET request
    $test->mech->get("/oauth2/token?client_id=id-desktop&client_secret=id-desktop-secret&grant_type=authorization_code&redirect_uri=urn:ietf:wg:oauth:2.0:oob&code=$code");
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'invalid_request');

    # No problems, receives access token
    $test->mech->post_ok('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-desktop-secret',
        grant_type => 'authorization_code',
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
        code => $code,
    });
    $response = from_json($test->mech->content);
    is($response->{error}, undef);
    is($response->{error_description}, undef);
    is($response->{token_type}, 'bearer');
    ok($response->{access_token});
    ok($response->{refresh_token});
    ok($response->{expires_in});
};

test 'Exchange refresh code' => sub {
    my $test = shift;

    MusicBrainz::Server::Test->prepare_test_database($test->c, '+oauth');

    my ($code, $response);

    # Unknown refresh token
    $code = "xxxxxxxxxxxxxxxxxxxxxx";
    $test->mech->post('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-desktop-secret',
        grant_type => 'refresh_token',
        refresh_token => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'invalid_grant');

    # Correct token, but incorrect application
    $code = "yi3qjrMf4hG9VVUxXMVIuQ";
    $test->mech->post('/oauth2/token', {
        client_id => 'id-web',
        client_secret => 'id-web-secret',
        grant_type => 'refresh_token',
        refresh_token => $code,
    });
    $response = from_json($test->mech->content);
    is($test->mech->status, 400);
    is($response->{error}, 'invalid_grant');

    # No problems, receives access token
    $test->mech->post_ok('/oauth2/token', {
        client_id => 'id-desktop',
        client_secret => 'id-desktop-secret',
        grant_type => 'refresh_token',
        refresh_token => $code,
    });
    $response = from_json($test->mech->content);
    is($response->{token_type}, 'bearer');
    ok($response->{access_token});
    ok($response->{refresh_token});
    ok($response->{expires_in});
    $test->mech->header_is('access-control-allow-origin', '*');
};

test 'Token info' => sub {
    my $test = shift;

    MusicBrainz::Server::Test->prepare_test_database($test->c, '+oauth');

    my ($code, $response);

    # CORS preflight
    $test->mech->request(HTTP::Request->new(OPTIONS => '/oauth2/tokeninfo'));
    $response = $test->mech->response;
    is($response->code, 200);
    is($response->header('allow'), 'GET, OPTIONS');
    is($response->header('access-control-allow-origin'), '*');

    # Unknown token
    $code = "xxxxxxxxxxxxxxxxxxxxxx";
    $test->mech->get("/oauth2/tokeninfo?access_token=$code");
    is($test->mech->status, 400);
    $response = from_json($test->mech->content);
    is($response->{error}, 'invalid_token');

    # Expired token
    $code = "3fxf40Z5r6K78D9b031xaw";
    $test->mech->get("/oauth2/tokeninfo?access_token=$code");
    is($test->mech->status, 400);
    $response = from_json($test->mech->content);
    is($response->{error}, 'invalid_token');

    # Valid token
    $code = "Nlaa7v15QHm9g8rUOmT3dQ";
    $test->mech->get("/oauth2/tokeninfo?access_token=$code");
    is($test->mech->status, 200);
    $response = from_json($test->mech->content);
    ok($response->{expires_in});
    delete $response->{expires_in};
    is($response->{audience}, 'id-desktop');
    is($response->{issued_to}, 'id-desktop');
    is($response->{access_type}, 'offline');
    is($response->{token_type}, 'Bearer');
    cmp_set(
        [ split /\s+/, $response->{scope} ],
        [ qw( profile collection rating email tag submit_barcode submit_isrc ) ]
    );
    $test->mech->header_is('access-control-allow-origin', '*');
};

test 'User info' => sub {
    my $test = shift;

    MusicBrainz::Server::Test->prepare_test_database($test->c, '+oauth');

    my ($code, $response);

    # CORS preflight
    $test->mech->request(HTTP::Request->new(OPTIONS => '/oauth2/userinfo'));
    $response = $test->mech->response;
    is($response->code, 200);
    is($response->header('allow'), 'GET, OPTIONS');
    is($response->header('access-control-allow-headers'), 'authorization');
    is($response->header('access-control-allow-origin'), '*');

    # Unknown token
    $code = "xxxxxxxxxxxxxxxxxxxxxx";
    $test->mech->get("/oauth2/userinfo?access_token=$code");
    is($test->mech->status, 401);

    # Expired token
    $code = "3fxf40Z5r6K78D9b031xaw";
    $test->mech->get("/oauth2/userinfo?access_token=$code");
    is($test->mech->status, 401);

    # Valid token with email
    $code = "Nlaa7v15QHm9g8rUOmT3dQ";
    $test->mech->get("/oauth2/userinfo?access_token=$code");
    is($test->mech->status, 200);
    $response = from_json(decode('utf8', $test->mech->content(raw => 1)));
    is_deeply($response, {
        sub => 'editor1',
        profile => 'http://localhost/user/editor1',
        website => 'http://www.mysite.com/',
        gender => 'male',
        zoneinfo => 'Europe/Bratislava',
        email => 'me@mysite.com',
        email_verified => JSON::true,
        metabrainz_user_id => 11,
    });
    $test->mech->header_is('access-control-allow-origin', '*');

    # Valid token without email
    $code = "7Fjfp0ZBr1KtDRbnfVdmIw";
    $test->mech->get("/oauth2/userinfo?access_token=$code");
    is($test->mech->status, 200);
    $response = from_json(decode('utf8', $test->mech->content(raw => 1)));
    is_deeply($response, {
        sub => 'editor1',
        profile => 'http://localhost/user/editor1',
        website => 'http://www.mysite.com/',
        gender => 'male',
        zoneinfo => 'Europe/Bratislava',
        metabrainz_user_id => 11,
    });

    # MBS-9744
    $code = 'h_UngEx7VcA6I-XybPS13Q';
    $test->mech->get("/oauth2/userinfo?access_token=$code");
    is($test->mech->status, 200);
    $response = from_json(decode('utf8', $test->mech->content(raw => 1)));
    is_deeply($response, {
        metabrainz_user_id => 14,
        profile => 'http://localhost/user/%C3%A6ditor%E2%85%A3',
        sub => 'æditorⅣ',
        zoneinfo => 'UTC',
    });

    # Deleted users (bearer)
    $test->c->sql->do('UPDATE editor SET deleted = true WHERE id = 14');
    $test->mech->get("/oauth2/userinfo?access_token=$code");
    is(401, $test->mech->status);
    $test->mech->get('/oauth2/userinfo', {Authorization => "Bearer $code"});
    is(401, $test->mech->status);
};

1;
